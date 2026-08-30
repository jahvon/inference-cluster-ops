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

bash scripts/tunnel.sh ensure >/dev/null || exit 1

export KUBECONFIG="$PWD/kubeconfig"

RANGE="$RANGE" STEP="$STEP" python3 - <<'PY'
import json, os, subprocess, sys, time, urllib.parse

RANGE = os.environ["RANGE"]
STEP = os.environ["STEP"]

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
    """Latest value of an instant query, or None."""
    res, err = promq("query", {"query": expr})
    if err or not res:
        return None
    try:
        return float(res[0]["value"][1])
    except (KeyError, IndexError, ValueError):
        return None


now = time.time()
span = dur(RANGE)
step = dur(STEP)

report = {
    "range": {"duration": RANGE, "step": STEP,
              "from": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now - span)),
              "to": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now))},
}

series, err = promq("query_range", {
    "query": "sli:vllm:healthy", "start": f"{now - span:.0f}",
    "end": f"{now:.0f}", "step": f"{step:.0f}",
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
    report["reason"] = ("no sli:vllm:healthy series -- the recording rules in "
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
}

report["current"] = {
    "ttft_p50_seconds": scalar("sli:vllm:ttft_seconds:p50"),
    "ttft_p95_seconds": scalar("sli:vllm:ttft_seconds:p95"),
    "ttft_p99_seconds": scalar("sli:vllm:ttft_seconds:p99"),
    "tpot_p95_seconds": scalar("sli:vllm:tpot_seconds:p95"),
    "itl_p99_seconds": scalar("sli:vllm:itl_seconds:p99"),
    "e2e_p50_seconds": scalar("sli:vllm:e2e_seconds:p50"),
    "e2e_p95_seconds": scalar("sli:vllm:e2e_seconds:p95"),
    "e2e_p99_seconds": scalar("sli:vllm:e2e_seconds:p99"),
    "queue_p95_seconds": scalar("sli:vllm:queue_seconds:p95"),
    "queue_p99_seconds": scalar("sli:vllm:queue_seconds:p99"),
    "error_ratio": scalar("sli:envoy:error_ratio:rate5m"),
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

tenants, terr = promq("query", {"query": "sli:tenant:requests:rate5m"})
report["tenants"] = [] if terr or not tenants else sorted(
    ({"name": m["metric"].get("envoy_virtual_cluster", "?"),
      "requests_per_second": round(float(m["value"][1]), 4)}
     for m in tenants), key=lambda t: -t["requests_per_second"])

print(json.dumps(report, indent=2))
PY
