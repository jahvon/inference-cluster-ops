#!/usr/bin/env bash
# Measure the SLO over a time window and emit it as JSON.
#
# Data only -- no presentation, same contract as scripts/status.sh. `make slo` prints
# the JSON; `flow show slo` renders it through docs/slo.md. One place gathers, one
# place formats.
set -uo pipefail

. scripts/ssh-env.sh
require_node || exit 1

RANGE="${SLO_RANGE:-1h}"
STEP="${SLO_STEP:-15s}"

# An explicit window, as epoch seconds. Set by the experiment harness to pin the
# report to one rollout; SLO_TO defaults to now so a run still in flight can be
# read. When SLO_FROM is unset this stays a trailing SLO_RANGE window, which is
# what `flow show slo` wants.
FROM="${SLO_FROM:-}"
TO="${SLO_TO:-}"

# Which SLI family to measure against.
#
#   service   the :rate5m family -- "is the service healthy", what `flow show slo`
#             asks. Smooth on purpose.
#   rollout   the short-window family. A rollout is a ~500s event and a 5m rate
#             window buries the transitions inside it, so the experiment harness
#             asks for this one.
#
# Both are recorded from the same definitions over different windows, so the two
# reports are comparable -- they differ only in how much they smooth.
SCOPE="${SLO_SCOPE:-service}"
case "$SCOPE" in service|rollout) ;; *)
  echo "  SLO_SCOPE must be 'service' or 'rollout', got '$SCOPE'" >&2; exit 1 ;;
esac
ROLLOUT_WINDOW="$(cfg ROLLOUT_WINDOW 1m)"

bash scripts/tunnel.sh ensure >/dev/null || exit 1

export KUBECONFIG="$PWD/kubeconfig"

RANGE="$RANGE" STEP="$STEP" FROM="$FROM" TO="$TO" \
SCOPE="$SCOPE" ROLLOUT_WINDOW="$ROLLOUT_WINDOW" python3 - <<'PY'
import json, os, subprocess, sys, time, urllib.parse

RANGE = os.environ["RANGE"]
STEP = os.environ["STEP"]
FROM = os.environ.get("FROM", "").strip()
TO = os.environ.get("TO", "").strip()
SCOPE = os.environ["SCOPE"]
ROLLOUT_WINDOW = os.environ["ROLLOUT_WINDOW"]

# The four SLO-defining SLIs exist in both families; everything else in `current`
# is recorded at 5m only and is reported as-is.
SUF = ":rollout" if SCOPE == "rollout" else ""

# The operator-managed service name, fixed regardless of the helm release name.
PROXY = ("/api/v1/namespaces/monitoring/services/prometheus-operated:9090"
         "/proxy/api/v1")


def dur(s):
    """'90m' -> 5400.0. Prometheus duration subset, enough for a time range."""
    units = {"s": 1, "m": 60, "h": 3600, "d": 86400}
    if s and s[-1] in units and s[:-1].replace(".", "", 1).isdigit():
        return float(s[:-1]) * units[s[-1]]
    raise SystemExit(f"bad duration: {s!r} (use forms like 30m, 6h, 2d)")


def promq(path, params):
    url = f"{PROXY}/{path}?" + urllib.parse.urlencode(params)
    p = subprocess.run(["kubectl", "get", "--raw", url],
                       capture_output=True, text=True)
    if p.returncode != 0:
        err = (p.stderr or "").strip().splitlines()
        return None, (err[-1] if err else "kubectl failed")
    try:
        body = json.loads(p.stdout)
    except json.JSONDecodeError:
        return None, "Prometheus returned a non-JSON response"
    if body.get("status") != "success":
        return None, body.get("error", "query failed")
    return body["data"]["result"], None


def scalar(expr):
    """Value of an instant query at the window's end, or None.

    AT is set below, after the window is resolved. For a trailing window it stays
    None and this is a plain "latest value" query; for an explicit window it pins
    every instant query to t_to, so a report about a finished experiment describes
    that experiment rather than whatever the cluster is doing now.
    """
    params = {"query": expr}
    if AT is not None:
        params["time"] = f"{AT:.0f}"
    res, err = promq("query", params)
    if err or not res:
        return None
    try:
        v = float(res[0]["value"][1])
    except (KeyError, IndexError, ValueError):
        return None
    # A latency quantile over an idle window is NaN, not absent. json.dumps writes
    # that as a bare NaN, which is not valid JSON and which the doc renderer
    # rejects -- so an idle cluster would produce a report nothing could read.
    # None becomes null, and the templates already guard for it.
    return None if v != v else v


step = dur(STEP)


def epoch(name, s):
    try:
        return float(s)
    except ValueError:
        raise SystemExit(f"bad {name}: {s!r} (expected epoch seconds)")


if FROM:
    t_from = epoch("SLO_FROM", FROM)
    t_to = epoch("SLO_TO", TO) if TO else time.time()
    if t_to <= t_from:
        raise SystemExit(f"empty window: SLO_FROM={t_from:.0f} is not before SLO_TO={t_to:.0f}")
    span = t_to - t_from
    duration = f"{span:.0f}s"
else:
    t_to = time.time()
    span = dur(RANGE)
    t_from = t_to - span
    duration = RANGE

AT = t_to if FROM else None

report = {
    "range": {"duration": duration, "step": STEP,
              "from": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(t_from)),
              "to": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(t_to)),
              "from_epoch": round(t_from, 3), "to_epoch": round(t_to, 3),
              # The rate window behind the SLIs. A report window shorter than this
              # is dominated by traffic from before it, so it is published rather
              # than implying a precision the smoothing cannot deliver.
              "scope": SCOPE,
              "smoothed_by_seconds": dur(ROLLOUT_WINDOW) if SCOPE == "rollout" else 300},
}

series, err = promq("query_range", {
    "query": f"sli:vllm:healthy{SUF}", "start": f"{t_from:.0f}",
    "end": f"{t_to:.0f}", "step": f"{step:.0f}",
})

if err is not None:
    # Reachability is the single most common failure, and it has nothing to do with
    # the SLO. Report it as its own state rather than as a zero-availability outage.
    report["available"] = False
    report["reason"] = err
    print(json.dumps(report, indent=2))
    sys.exit(0)

if not series:
    report["available"] = False
    report["reason"] = (f"no sli:vllm:healthy{SUF} series -- the recording rules in "
                        "k8s/50-prometheus-rules.yaml are not loaded, or Prometheus "
                        "has not evaluated them yet (they need one interval)")
    print(json.dumps(report, indent=2))
    sys.exit(0)

report["available"] = True

points = [(float(ts), float(v)) for ts, v in series[0]["values"]]
total = len(points)
violating = sum(1 for _, v in points if v < 1)

# Walk the series and cut it into contiguous violation windows. A window's duration
# IS its recovery time: it starts when the SLI first reads unhealthy and ends at the
# first sample that reads healthy again.
incidents, start = [], None
for ts, v in points:
    if v < 1 and start is None:
        start = ts
    elif v >= 1 and start is not None:
        incidents.append((start, ts))
        start = None
ongoing = start is not None
if ongoing:
    incidents.append((start, points[-1][0]))


def clock(ts):
    return time.strftime("%H:%M:%S", time.localtime(ts))


report["slo"] = {
    "samples": total,
    "violating_samples": violating,
    # Sample-based, so it inherits the step's resolution. At the default 15s step
    # that is the same resolution the rules are evaluated at.
    "availability": round(1 - violating / total, 6) if total else None,
    "time_in_violation_seconds": round(violating * step, 1),
    "incident_count": len(incidents),
    "ongoing": ongoing,
}

report["incidents"] = [
    {"start": clock(a), "end": clock(b), "duration_seconds": round(b - a, 1),
     "recovered": not (ongoing and i == len(incidents) - 1)}
    for i, (a, b) in enumerate(incidents)
]

recovered = [b - a for i, (a, b) in enumerate(incidents)
             if not (ongoing and i == len(incidents) - 1)]
report["recovery"] = {
    "count": len(recovered),
    "longest_seconds": round(max(recovered), 1) if recovered else None,
    "mean_seconds": round(sum(recovered) / len(recovered), 1) if recovered else None,
}

report["objectives"] = {
    "ttft_p95_seconds": scalar("slo:objective:ttft_seconds"),
    "tpot_p95_seconds": scalar("slo:objective:tpot_seconds"),
    "error_ratio": scalar("slo:objective:error_ratio"),
    "truncation_ratio": scalar("slo:objective:truncation_ratio"),
}

report["current"] = {
    "ttft_p50_seconds": scalar("sli:vllm:ttft_seconds:p50"),
    "ttft_p95_seconds": scalar(f"sli:vllm:ttft_seconds:p95{SUF}"),
    "ttft_p99_seconds": scalar("sli:vllm:ttft_seconds:p99"),
    "tpot_p95_seconds": scalar(f"sli:vllm:tpot_seconds:p95{SUF}"),
    "itl_p99_seconds": scalar("sli:vllm:itl_seconds:p99"),
    "e2e_p50_seconds": scalar("sli:vllm:e2e_seconds:p50"),
    "e2e_p95_seconds": scalar("sli:vllm:e2e_seconds:p95"),
    "e2e_p99_seconds": scalar("sli:vllm:e2e_seconds:p99"),
    "queue_p95_seconds": scalar("sli:vllm:queue_seconds:p95"),
    "queue_p99_seconds": scalar("sli:vllm:queue_seconds:p99"),
    "error_ratio": scalar(f"sli:envoy:error_ratio:{'rollout' if SCOPE == 'rollout' else 'rate5m'}"),
    # Streams cut off mid-generation. Neither error ratio above counts one -- the
    # client already had a 200.
    "truncation_ratio": scalar(f"sli:envoy:truncation_ratio:{'rollout' if SCOPE == 'rollout' else 'rate5m'}"),
    "output_tokens_per_second": scalar("sli:vllm:output_tokens:rate5m"),
    "output_tokens_per_gpu": scalar("sli:vllm:output_tokens_per_gpu:rate5m"),
    "output_tokens_per_stream": scalar("sli:vllm:output_tokens_per_stream:rate5m"),
    "requests_running": scalar("sli:vllm:requests_running"),
    "requests_waiting": scalar("sli:vllm:requests_waiting"),
    "kv_cache_usage": scalar("sli:vllm:kv_cache_usage:max"),
    # None when the DCP profiling fields are unavailable -- see 35-dcgm-exporter.yaml.
    "gpu_engine_active": scalar("sli:gpu:engine_active"),
    "gpu_util_coarse": scalar("sli:gpu:util_coarse"),
}

# Serving capacity across the window. With maxSurge:0 the fleet runs at (N-1)/N for
# the whole pod-replacement window, and no latency percentile shows that as long as
# the surviving pods absorb the traffic -- so it needs its own number.
cap, caperr = promq("query_range", {
    "query": "sli:rollout:capacity_ratio", "start": f"{t_from:.0f}",
    "end": f"{t_to:.0f}", "step": f"{step:.0f}",
})
if caperr or not cap:
    report["capacity"] = {"available": False}
else:
    vals = [float(v) for _, v in cap[0]["values"]]
    degraded = sum(1 for v in vals if v < 0.999)
    report["capacity"] = {
        "available": True,
        "min_ratio": round(min(vals), 4),
        "mean_ratio": round(sum(vals) / len(vals), 4),
        "samples": len(vals),
        "degraded_samples": degraded,
        "seconds_below_full": round(degraded * step, 1),
        "replicas_desired": scalar("sli:rollout:replicas_desired"),
        "replicas_available": scalar("sli:rollout:replicas_available"),
    }

_tp = {"query": "sli:tenant:requests:rate5m"}
if AT is not None:
    _tp["time"] = f"{AT:.0f}"
tenants, terr = promq("query", _tp)
report["tenants"] = [] if terr or not tenants else sorted(
    ({"name": m["metric"].get("envoy_virtual_cluster", "?"),
      "requests_per_second": round(float(m["value"][1]), 4)}
     for m in tenants), key=lambda t: -t["requests_per_second"])

print(json.dumps(report, indent=2))
PY
