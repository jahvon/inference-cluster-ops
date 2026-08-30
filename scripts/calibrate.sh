#!/usr/bin/env bash
# One-shot calibration: measure the latency and throughput baseline, as JSON.
#
# Same split as scripts/status.sh -- this gathers, docs/bench.md formats.
set -uo pipefail

. scripts/ssh-env.sh
require_node || exit 1

bash scripts/tunnel.sh ensure >/dev/null || exit 1

export KUBECONFIG="$PWD/kubeconfig"

# A baseline measured while the sustained generators are running is not a baseline,
# it is a contention measurement -- and it would silently become the number the SLO
# thresholds get set from.
if kubectl -n inference get deploy -l app=load-generator \
     -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | grep -q .; then
  echo "  The sustained load generators are running." >&2
  echo "  Calibrating now would measure contention, not a baseline." >&2
  echo "" >&2
  echo "    flow stop load     then run this again" >&2
  exit 1
fi

bash k8s/bootstrap.sh --render-only >/dev/null 2>&1 || {
  echo "  Could not render manifests. Run 'make render' to see why." >&2
  exit 1
}

JOB=k8s/rendered/70-bench-job.yaml
[ -f "$JOB" ] || { echo "  $JOB missing after render." >&2; exit 1; }

# A Job's pod template is immutable, so a re-run replaces rather than applies over.
# --wait blocks until the old pod is gone; without it the new Job collides with the
# terminating one.
kubectl -n inference delete job vllm-bench --ignore-not-found --wait >/dev/null 2>&1

kubectl apply -f "$JOB" >/dev/null || {
  echo "  Could not create the calibration job." >&2
  exit 1
}

echo "  running calibration..." >&2

TIMEOUT="${BENCH_TIMEOUT:-20m}"
kubectl -n inference wait --for=condition=complete job/vllm-bench \
  --timeout="$TIMEOUT" >/dev/null 2>&1
STATUS=$?

LOGS=$(kubectl -n inference logs job/vllm-bench --tail=-1 2>/dev/null)

if [ "$STATUS" -ne 0 ]; then
  FAILED=$(kubectl -n inference get job vllm-bench -o jsonpath='{.status.failed}' 2>/dev/null)
  echo "" >&2
  if [ -n "$FAILED" ] && [ "$FAILED" != "0" ]; then
    echo "  The calibration job failed. Last lines:" >&2
  else
    echo "  Calibration did not finish within $TIMEOUT. Last lines:" >&2
  fi
  echo "" >&2
  printf '%s\n' "$LOGS" | tail -20 | sed 's/^/    /' >&2
  echo "" >&2
  echo "  Full output:  kubectl -n inference logs job/vllm-bench" >&2
  exit 1
fi

CONCURRENCY=$(cfg BENCH_CONCURRENCY 16)
MODEL=$(cfg SERVED_MODEL_NAME "")
TTFT_SLO=$(cfg TTFT_P95_THRESHOLD 0)
TPOT_SLO=$(cfg TPOT_P95_THRESHOLD 0)

printf '%s' "$LOGS" | CONCURRENCY="$CONCURRENCY" MODEL="$MODEL" \
  TTFT_SLO="$TTFT_SLO" TPOT_SLO="$TPOT_SLO" python3 -c '
import json, os, re, sys

raw = sys.stdin.read()

# inference-perf prints its report as a JSON object on stdout, surrounded by log
# lines and rich tables. raw_decode lifts the first complete object out rather than
# trying to regex a balanced brace.
dec = json.JSONDecoder()
report = None
for m in re.finditer(r"^\{", raw, re.M):
    try:
        report, _ = dec.raw_decode(raw[m.start():])
        break
    except ValueError:
        continue

if report is None or "successes" not in report:
    print(json.dumps({"ok": False,
                      "reason": "inference-perf produced no parsable report"}, indent=2))
    sys.exit(0)

ok_ = report["successes"]
lat = ok_.get("latency", {})
thr = ok_.get("throughput", {})
conc = float(os.environ["CONCURRENCY"] or 0)


def rnd(v, n=4):
    return round(v, n) if isinstance(v, (int, float)) else v


def dist(name):
    """Percentiles for one latency metric. inference-perf calls p50 median."""
    d = lat.get(name)
    if not d:
        return None
    out = {}
    for label, key in (("mean", "mean"), ("p50", "median"),
                       ("p90", "p90"), ("p95", "p95"), ("p99", "p99")):
        if d.get(key) is not None:
            out[label] = round(d[key], 4)
    return out or None


def attainment(name, objective):
    """
    How far up the distribution the objective still holds.

    A coarse bracket, kept as a fallback: it reports the highest measured percentile
    still under the objective, so "p99" means at least 99% of requests met it and
    "below p50" means most did not.

    Superseded by the goodput block below whenever the harness reports one -- that is
    a real per-request pass/fail rather than an inference from percentiles.
    """
    d = lat.get(name)
    if not d or not objective:
        return None
    best = None
    for label, key in (("p50", "median"), ("p90", "p90"), ("p95", "p95"), ("p99", "p99")):
        v = d.get(key)
        if v is None:
            continue
        if v < objective:
            best = label
        else:
            break
    return best or "below p50"


prompt = ok_.get("prompt_tokens", {})
outtok = ok_.get("output_tokens", {})

out = {
    "ok": True,
    "harness": "kubernetes-sigs/inference-perf",
    "config": {
        "concurrency": int(conc) if conc else None,
        "num_prompts": ok_.get("count"),
        "input_len": rnd(prompt.get("mean"), 0),
        "output_len": rnd(outtok.get("mean"), 0),
        "model": os.environ.get("MODEL") or None,
        "duration_seconds": rnd(report.get("benchmark_time_seconds"), 2),
    },
    "throughput": {
        "requests_per_second": rnd(thr.get("requests_per_sec"), 3),
        "output_tokens_per_second": rnd(thr.get("output_tokens_per_sec"), 2),
        "total_tokens_per_second": rnd(thr.get("total_tokens_per_sec"), 2),
        "completed": ok_.get("count"),
        "total_input_tokens": rnd(prompt.get("total"), 0),
        "total_output_tokens": rnd(outtok.get("total"), 0),
    },
    "latency": {},
}

# Per-stream rate: what ONE user sees, as opposed to what the fleet aggregates to.
# Exact here because the client knows how many streams it held open -- this is the
# number the dashboard can only estimate from the server side.
otps = thr.get("output_tokens_per_sec")
if isinstance(otps, (int, float)) and conc:
    out["throughput"]["output_tokens_per_second_per_user"] = round(otps / conc, 2)

for label, key in (("ttft", "time_to_first_token"),
                   ("tpot", "time_per_output_token"),
                   ("itl", "inter_token_latency"),
                   ("e2el", "request_latency")):
    d = dist(key)
    if d:
        out["latency"][label] = d

out["slo_attainment"] = {
    "ttft_objective_seconds": float(os.environ["TTFT_SLO"]) or None,
    "ttft_met_through": attainment("time_to_first_token", float(os.environ["TTFT_SLO"] or 0)),
    "tpot_objective_seconds": float(os.environ["TPOT_SLO"]) or None,
    "tpot_met_through": attainment("time_per_output_token", float(os.environ["TPOT_SLO"] or 0)),
}

failures = report.get("failures", {}).get("count")
if failures:
    out["errors"] = failures

# Real goodput: the fraction of requests that met EVERY constraint, evaluated per
# request by the harness rather than inferred from percentiles.
#
# One correction is needed. inference-perf divides by successful requests only, so
# its goodput_percentage answers "of the requests that completed, how many were fast
# enough" -- a run where nine tenths of requests errored and the rest were quick
# would report 100%. Multiplying by the success ratio gives the number a user would
# recognise: of everything sent, how much came back both correct AND on time.
gp = ok_.get("goodput_metrics") or {}
if gp:
    ok_count = ok_.get("count") or 0
    fail_count = report.get("failures", {}).get("count") or 0
    sent = ok_count + fail_count
    success_ratio = (ok_count / sent) if sent else None
    among_ok = gp.get("goodput_percentage")

    block = {
        "good_requests": gp.get("good_requests"),
        "total_requests": gp.get("total_requests"),
        # As inference-perf reports it: share of SUCCESSFUL requests meeting the SLO.
        "percentage_of_successful": rnd(among_ok, 2),
        "success_ratio": rnd(success_ratio, 4),
        "request_goodput_per_second": rnd(gp.get("request_goodput"), 3),
        "token_goodput_per_second": rnd(gp.get("token_goodput"), 2),
        "constraints": {
            "ttft_seconds": float(os.environ["TTFT_SLO"]) or None,
            "tpot_seconds": float(os.environ["TPOT_SLO"]) or None,
        },
    }
    if isinstance(among_ok, (int, float)) and success_ratio is not None:
        block["percentage_of_all_sent"] = round(among_ok * success_ratio, 2)

    # Per-constraint attainment, so a miss says WHICH objective it missed.
    per = {k[:-len("_attainment_percentage")]: rnd(v, 2)
           for k, v in gp.items() if k.endswith("_attainment_percentage")}
    if per:
        block["attainment_percentage"] = [{"name": k, "percentage": v}
                                          for k, v in sorted(per.items())]
    out["goodput"] = block

print(json.dumps(out, indent=2))
'
