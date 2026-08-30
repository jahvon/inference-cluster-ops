#!/usr/bin/env bash
# Turn one run directory into a single JSON blob, as data only.
#
#   report.sh [RUN_ID]     one run   (default: the most recent)
#   report.sh --all        every run, for comparison
#
# Same split as scripts/slo-report.sh: this gathers, docs/experiment.md formats.
set -uo pipefail

MODE="${1:-}"

. scripts/ssh-env.sh

# The curves come from Prometheus at a 1m rate window rather than from the sli:
# recording rules, which are all rate(...[5m]). A rollout lasts 2-4 minutes, so the
# 5m rules smear exactly the transient these experiments exist to resolve. The rules
# stay as they are -- they serve the SLO and the gate, which want the smoothing.
NEED_PROM=1
[ "$MODE" = "--all" ] && NEED_PROM=0
if [ "$NEED_PROM" -eq 1 ]; then
  bash scripts/tunnel.sh ensure >/dev/null 2>&1
fi
export KUBECONFIG="$PWD/kubeconfig"

MODE="$MODE" python3 - <<'PY'
import datetime, json, os, pathlib, subprocess, time, urllib.parse

MODE = os.environ.get("MODE", "")
RUNS = pathlib.Path("runs")

PROXY = ("/api/v1/namespaces/monitoring/services/prometheus-operated:9090"
         "/proxy/api/v1")


def promq(path, params):
    url = f"{PROXY}/{path}?" + urllib.parse.urlencode(params)
    p = subprocess.run(["kubectl", "get", "--raw", url], capture_output=True, text=True)
    if p.returncode != 0:
        return None
    try:
        body = json.loads(p.stdout)
    except json.JSONDecodeError:
        return None
    if body.get("status") != "success":
        return None
    return body["data"]["result"]


def load_json(p, default=None):
    try:
        return json.loads(p.read_text())
    except Exception:
        return default


def load_jsonl(p):
    out = []
    try:
        for line in p.read_text().splitlines():
            line = line.strip()
            if line:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
    except Exception:
        pass
    return out


def pct(xs, q, scale=1.0):
    xs = sorted(x * scale for x in xs if x is not None)
    if not xs:
        return None
    k = max(0, min(len(xs) - 1, int(round((len(xs) - 1) * q))))
    return round(xs[k], 4)


def parse_ts(t):
    """Envoy's %START_TIME% is RFC3339 with fractional seconds and a Z."""
    if not t:
        return None
    try:
        t = t.replace("Z", "+00:00")
        return datetime.datetime.fromisoformat(t).timestamp()
    except ValueError:
        return None


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def classify(r):
    """What the client actually got, from Envoy's own record of the exchange.

    response_code_details is the discriminator, not the flags. Envoy cannot retry
    once response headers have gone downstream, so these are genuinely different
    kinds of damage and not two views of one:

      truncated -- a 200 the client began reading and then lost. Unretryable by
                   construction, and invisible to every vLLM metric.
      rejected  -- the client got an error; retries were exhausted or it was not
                   retryable.
      masked    -- an upstream failure the retry policy hid. The client saw a clean
                   200, and the only trace is that it took more than one attempt.
    """
    details = r.get("details") or ""
    status = num(r.get("status"))
    attempts = num(r.get("attempts")) or 1

    if details.startswith("upstream_reset_after_response_started"):
        return "truncated"
    if status is not None and status >= 500:
        return "rejected"
    if details.startswith("upstream_reset_before_response_started"):
        return "rejected"
    if attempts > 1:
        return "masked"
    return "complete"


def requests_summary(recs, t0, t1):
    win = []
    for r in recs:
        ts = parse_ts(r.get("t"))
        if ts is None or not (t0 <= ts <= t1):
            continue
        r = dict(r, _ts=ts, _class=classify(r))
        win.append(r)

    by = {k: [r for r in win if r["_class"] == k]
          for k in ("complete", "truncated", "rejected", "masked")}
    n = len(win) or 1

    def bytes_of(rs):
        return [b for b in (num(r.get("bytes_sent")) for r in rs) if b is not None]

    complete_bytes = bytes_of(by["complete"])
    trunc_bytes = bytes_of(by["truncated"])
    median_complete = pct(complete_bytes, 0.50)
    median_trunc = pct(trunc_bytes, 0.50)

    # Envoy counts bytes, not tokens. The ratio of the two medians is still a fair
    # answer to "how far into the generation did it die", and it needs no tokenizer.
    depth = None
    if median_complete and median_trunc is not None and median_complete > 0:
        depth = round(median_trunc / median_complete, 4)

    return {
        "total": len(win),
        "complete": len(by["complete"]),
        "truncated": len(by["truncated"]),
        "rejected": len(by["rejected"]),
        "retry_masked": len(by["masked"]),
        "truncation_rate": round(len(by["truncated"]) / n, 4),
        "rejection_rate": round(len(by["rejected"]) / n, 4),
        "ttfb_p50_seconds": pct([num(r.get("ttfb_ms")) for r in by["complete"]], 0.50, 0.001),
        "ttfb_p95_seconds": pct([num(r.get("ttfb_ms")) for r in by["complete"]], 0.95, 0.001),
        "median_bytes_complete": median_complete,
        "median_bytes_truncated": median_trunc,
        "truncated_depth_fraction": depth,
        "by_tenant": sorted(
            ({"name": t,
              "total": sum(1 for r in win if r.get("tenant") == t),
              "truncated": sum(1 for r in win
                               if r.get("tenant") == t and r["_class"] == "truncated"),
              "rejected": sum(1 for r in win
                              if r.get("tenant") == t and r["_class"] == "rejected")}
             for t in {r.get("tenant") for r in win} - {None, "", "-"}),
            key=lambda d: -d["total"]),
        # Which pod served what. During a rollout this separates the fresh replica
        # from the established one without needing the role label.
        "by_upstream": sorted(
            ({"host": h,
              "total": sum(1 for r in win if r.get("upstream") == h),
              "truncated": sum(1 for r in win
                               if r.get("upstream") == h and r["_class"] == "truncated"),
              "ttfb_p95_seconds": pct(
                  [num(r.get("ttfb_ms")) for r in win
                   if r.get("upstream") == h and r["_class"] == "complete"], 0.95, 0.001)}
             for h in {r.get("upstream") for r in win} - {None, "", "-"}),
            key=lambda d: -d["total"]),
        "detail_classes": sorted(
            ({"name": d, "count": sum(1 for r in win if (r.get("details") or "") == d)}
             for d in {(r.get("details") or "") for r in win
                       if (r.get("details") or "") not in ("", "via_upstream")}),
            key=lambda d: -d["count"]),
    }


def series(expr, t0, t1, step=15):
    res = promq("query_range", {"query": expr, "start": f"{t0:.0f}",
                                "end": f"{t1:.0f}", "step": str(step)})
    out = {}
    for m in res or []:
        label = m["metric"].get("role") or m["metric"].get("pod") or "all"
        pts = []
        for ts, v in m["values"]:
            try:
                fv = float(v)
            except ValueError:
                continue
            if fv == fv:  # drop NaN: histogram_quantile returns it for an idle window
                pts.append([float(ts), round(fv, 4)])
        out[label] = pts
    return out


def curves(t0, t1):
    q = "[1m]"
    ttft = ("histogram_quantile(0.95, sum by (le, role) "
            f"(rate(vllm:time_to_first_token_seconds_bucket{q}))) >= 0")
    infl = "sum by (role) (avg by (pod, engine, role) (vllm:num_requests_running))"
    reps = "count(group by (pod) (up{job=~\"vllm-.*\"} == 1))"
    return {
        "ttft_p95_by_role": series(ttft, t0, t1),
        "inflight_by_role": series(infl, t0, t1),
        "replicas_up": series(reps, t0, t1),
    }


def cold_pod_share(c):
    """How much in-flight work the fresh pod took while it was still warming.

    This is Scenario A's finding as a single number. LEAST_REQUEST picks the endpoint
    with the fewest outstanding requests, and a pod that just went Ready has almost
    none -- so it reads as idle and gets chosen precisely while it is slowest. With
    two replicas an even split is ~0.5; anything at or above that means the balancer
    gave the cold pod a full share rather than easing it in.
    """
    infl = c.get("inflight_by_role", {})
    can, sta = infl.get("canary") or [], infl.get("stable") or []
    if not can or not sta:
        return None
    sta_at = {int(ts): v for ts, v in sta}
    first = None
    shares = []
    for ts, v in can:
        other = sta_at.get(int(ts))
        if other is None:
            continue
        tot = v + other
        if tot <= 0:
            continue
        if first is None and v > 0:
            first = ts
        if first is not None and ts - first <= 60:
            shares.append(v / tot)
    if not shares:
        return None
    return {"first_traffic_ts": first,
            "mean_share_first_60s": round(sum(shares) / len(shares), 4),
            "samples": len(shares)}


def one(d):
    meta = load_json(d / "meta.json")
    if not meta:
        return None
    slo = load_json(d / "slo.json", {})
    tl = load_jsonl(d / "timeline.jsonl")
    reqs = load_jsonl(d / "requests.jsonl")
    t0, t1 = meta["t_start"], meta["t_end"]

    rec = {
        "ok": True,
        "meta": meta,
        "requests": requests_summary(reqs, t0, t1),
        "slo": slo.get("slo") if slo.get("available") else None,
        "incidents": slo.get("incidents", []) if slo.get("available") else [],
        "objectives": slo.get("objectives") if slo.get("available") else None,
        "timeline": [e for e in tl if e.get("kind") in ("rollout", "analysis")],
        "pod_events": [e for e in tl if e.get("kind") == "pod"],
    }
    if MODE != "--all":
        c = curves(t0, t1)
        rec["curves"] = c
        rec["cold_pod_share"] = cold_pod_share(c)
    return rec


dirs = sorted([p for p in RUNS.glob("*") if p.is_dir()]) if RUNS.is_dir() else []

if MODE == "--all":
    runs = [r for r in (one(d) for d in dirs) if r]
    print(json.dumps({"ok": bool(runs), "count": len(runs),
                      "reason": None if runs else "No runs yet. Try: flow run experiment",
                      "runs": runs}, indent=2))
elif MODE and not MODE.startswith("--"):
    d = RUNS / MODE
    r = one(d) if d.is_dir() else None
    print(json.dumps(r or {"ok": False, "reason": f"No run '{MODE}' in runs/"}, indent=2))
else:
    r = one(dirs[-1]) if dirs else None
    print(json.dumps(r or {"ok": False,
                           "reason": "No runs yet. Try: flow run experiment"}, indent=2))
PY
