#!/usr/bin/env bash
# Drive one rollout scenario under load and measure what it did.
#
#   run.sh <scenario> [variant]
#
# Env:
#   EXPERIMENT_REPEAT=N   roll N times (the false-positive study; default 1)
#   EXPERIMENT_SETTLE=S   seconds to let metrics settle before measuring (default 30)
#   EXPERIMENT_TIMEOUT=S  give up on a rollout after this long (default 1200)
#
# Every scenario here deliberately damages a live, billed cluster, so teardown runs
# from a trap on EXIT -- a run that dies halfway still stops the load and puts the
# fleet back on the baseline revision.
set -uo pipefail

SCENARIO="${1:-}"
VARIANT="${2:-stock}"

usage() {
  echo "  usage: run.sh <scenario> [variant]" >&2
  echo "" >&2
  echo "  available:" >&2
  for d in experiments/*/; do
    [ -d "$d" ] || continue
    for v in "$d"*.env; do
      [ -f "$v" ] || continue
      printf '    %-16s %s\n' "$(basename "$d")" "$(basename "$v" .env)" >&2
    done
  done
}

[ -z "$SCENARIO" ] && { usage; exit 1; }

OVERLAY="experiments/$SCENARIO/$VARIANT.env"
if [ ! -f "$OVERLAY" ]; then
  echo "  No such scenario/variant: $OVERLAY" >&2
  echo "" >&2
  usage
  exit 1
fi

REPEAT="${EXPERIMENT_REPEAT:-1}"
SETTLE="${EXPERIMENT_SETTLE:-30}"
TIMEOUT="${EXPERIMENT_TIMEOUT:-1200}"

. scripts/ssh-env.sh
require_node || exit 1
bash scripts/tunnel.sh ensure >/dev/null || exit 1
export KUBECONFIG="$PWD/kubeconfig"

HOST_CACHE=$(cfg HF_CACHE_HOSTPATH /opt/data/huggingface)
CTR_CACHE=/root/.cache/huggingface

kro() { kubectl -n inference get rollout vllm -o jsonpath="$1" 2>/dev/null; }

# Apply ONLY what an experiment can change: the Rollout's pod template and the gate
# it is judged by.
#
# Deliberately not scripts/deploy.sh. That runs the full bootstrap, which restarts
# Envoy so a ConfigMap edit takes effect -- and Envoy's access log is what this
# harness measures truncations FROM. Restarting it mid-run discards the records
# already collected and resets the counters. It also re-runs three no-op helm
# upgrades, turning a two-second step into a minute.
#
# The AnalysisTemplate goes first so a gate-tuning variant is in place before the
# rollout that will be judged by it.
apply_revision() {
  bash k8s/bootstrap.sh --render-only || return 1
  kubectl apply -f k8s/rendered/60-analysis-template.yaml || return 1
  kubectl apply -f k8s/rendered/40-vllm-rollout.yaml || return 1
}

# ---------------------------------------------------------------------------
# Guards. A rollout already in flight means the fleet is not at the steady state
# every one of these scenarios measures a departure FROM.
# ---------------------------------------------------------------------------
PHASE=$(kro '{.status.phase}')
if [ -z "$PHASE" ]; then
  echo "  Cannot read the vllm Rollout. Is the workload deployed?" >&2
  echo "    flow deploy workloads" >&2
  exit 1
fi
if [ "$PHASE" != "Healthy" ]; then
  echo "  The rollout is '$PHASE', not Healthy." >&2
  echo "  Starting from a fleet already in motion measures the wrong thing." >&2
  echo "" >&2
  echo "    flow show rollout      then re-run once it settles" >&2
  exit 1
fi

STARTED_LOAD=0
COLD_DIRS=""

cleanup() {
  rc=$?
  echo "" >&2
  echo "  restoring..." >&2
  # The loop kills the timeline collector on the normal path; an interrupt lands
  # here instead, and without this it is left polling the cluster and appending to
  # a finished run's file for the rest of the session.
  [ -n "${TL_PID:-}" ] && kill "$TL_PID" 2>/dev/null
  [ "$STARTED_LOAD" -eq 1 ] && bash scripts/load.sh stop >/dev/null 2>&1
  # Back to the baseline revision. Dropping the overrides is itself a pod-template
  # change, which is what makes Argo roll forward onto clean config -- and re-applying
  # the rendered Rollout restores spec.strategy too, so an ungated arm's patched-out
  # analysis step comes back by the same step.
  ( unset HF_HOME_PATH EXPERIMENT_NONCE EXTRA_VLLM_ARGS ROLLOUT_ANALYSIS \
          STARTUP_DELAY_SECONDS PRESTOP_SLEEP_SECONDS TERMINATION_GRACE_SECONDS
    apply_revision ) >/dev/null 2>&1
  for d in $COLD_DIRS; do
    [ -n "$d" ] && node_ssh "sudo rm -rf '$d'" >/dev/null 2>&1
  done
  echo "  done. Check the fleet with 'flow show slo'." >&2
  exit $rc
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Steady state. load.sh already waits for traffic to be FLOWING rather than merely
# Ready, which matters: a rollout measured against zero traffic measures nothing.
# ---------------------------------------------------------------------------
echo "  starting background load..." >&2
# RUN_ID is per-iteration, but an overlay may interpolate it (the cold-cache path
# does). Define it before this first source or `set -u` aborts here; the loop
# re-sources with the real value before anything uses it.
export RUN_ID=""
set -a; . "$OVERLAY"; set +a
bash scripts/load.sh start || { echo "  Could not start the load generators." >&2; exit 1; }
STARTED_LOAD=1

mkdir -p runs

for i in $(seq 1 "$REPEAT"); do
  RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$SCENARIO-$VARIANT"
  [ "$REPEAT" -gt 1 ] && RUN_ID="$RUN_ID-$(printf '%02d' "$i")"
  DIR="runs/$RUN_ID"
  mkdir -p "$DIR"

  echo "" >&2
  echo "  === $RUN_ID  ($i/$REPEAT) ===" >&2

  # Re-sourced per iteration because an overlay may interpolate RUN_ID.
  export RUN_ID
  export EXPERIMENT_NONCE="$RUN_ID"
  set -a; . "$OVERLAY"; set +a

  # A cold-cache variant writes into a subdir of the SAME hostPath mount, so the
  # warm cache the stable pods use is untouched and cleanup has a real path to
  # remove on the node.
  case "${HF_HOME_PATH:-}" in
    "$CTR_CACHE"/*) COLD_DIRS="$COLD_DIRS $HOST_CACHE/${HF_HOME_PATH#$CTR_CACHE/}" ;;
  esac

  # The ungated arm. spec.strategy is not part of the pod-template hash, so removing
  # the analysis step does not itself trigger a rollout -- it only changes what the
  # next one is judged by.
  if [ "${ROLLOUT_ANALYSIS:-on}" = "off" ]; then
    echo "  removing the analysis gate (ungated arm)" >&2
    kubectl -n inference patch rollout vllm --type=json \
      -p '[{"op":"remove","path":"/spec/strategy/canary/steps/1"}]' >/dev/null 2>&1
  fi

  # Nothing to deploy for measurement: Envoy is already in the path and already
  # writing a JSON access-log record per request. All this needs is a timestamp to
  # read its logs back from. Envoy is not restarted by the rollout, so its record of
  # the drain survives the pods that caused it.
  LOG_SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  BASE_HASH=$(kro '{.status.currentPodHash}')
  T_START=$(date +%s)

  bash scripts/experiment/timeline.sh "$DIR/timeline.jsonl" &
  TL_PID=$!

  echo "  applying revision..." >&2
  if ! apply_revision >"$DIR/deploy.log" 2>&1; then
    echo "  apply failed; see $DIR/deploy.log" >&2
    kill "$TL_PID" 2>/dev/null
    exit 1
  fi

  # Wait for the controller to notice, then for a terminal phase. Waiting on phase
  # alone would return instantly -- it is still 'Healthy' from before the deploy.
  for _ in $(seq 1 60); do
    [ "$(kro '{.status.currentPodHash}')" != "$BASE_HASH" ] && break
    sleep 1
  done

  echo "  watching rollout..." >&2
  ELAPSED=0
  while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    case "$(kro '{.status.phase}')" in Healthy|Degraded|Error) break ;; esac
    sleep 5
    ELAPSED=$((ELAPSED + 5))
  done
  FINAL_PHASE=$(kro '{.status.phase}')
  T_END=$(date +%s)
  TIMED_OUT=false; [ "$ELAPSED" -ge "$TIMEOUT" ] && TIMED_OUT=true

  echo "  rollout ended '$FINAL_PHASE' after $((T_END - T_START))s" >&2

  kill "$TL_PID" 2>/dev/null; wait "$TL_PID" 2>/dev/null

  # Let the last requests land in Prometheus before asking it what happened.
  sleep "$SETTLE"

  # Envoy logs one JSON object per request, interleaved with its own plain-text
  # startup lines -- so keep only the lines that parse as objects carrying a status.
  kubectl -n inference logs deploy/envoy --since-time="$LOG_SINCE" --tail=-1 2>/dev/null \
    | grep '^{' > "$DIR/requests.jsonl" || true

  RUN_ID="$RUN_ID" SCENARIO="$SCENARIO" VARIANT="$VARIANT" ITER="$i" OF="$REPEAT" \
  T_START="$T_START" T_END="$T_END" FINAL_PHASE="$FINAL_PHASE" TIMED_OUT="$TIMED_OUT" \
  GATED="$( [ "${ROLLOUT_ANALYSIS:-on}" = "off" ] && echo false || echo true )" \
  HF="${HF_HOME_PATH:-}" ARGS="${EXTRA_VLLM_ARGS:-}" \
  python3 - "$DIR/meta.json" <<'META'
import json, os, sys
json.dump({
    "run_id": os.environ["RUN_ID"],
    "scenario": os.environ["SCENARIO"],
    "variant": os.environ["VARIANT"],
    "iteration": int(os.environ["ITER"]), "of": int(os.environ["OF"]),
    "t_start": int(os.environ["T_START"]), "t_end": int(os.environ["T_END"]),
    "duration_seconds": int(os.environ["T_END"]) - int(os.environ["T_START"]),
    "final_phase": os.environ["FINAL_PHASE"],
    "timed_out": os.environ["TIMED_OUT"] == "true",
    "gated": os.environ["GATED"] == "true",
    "config": {"hf_home": os.environ["HF"], "extra_vllm_args": os.environ["ARGS"]},
}, open(sys.argv[1], "w"), indent=2)
META

  # Rollout scope: the short-window SLI family. A 5m rate window would smear this
  # ~500s rollout together with the steady state before it.
  SLO_SCOPE=rollout SLO_FROM="$T_START" SLO_TO="$((T_END + SETTLE))" \
    bash scripts/slo-report.sh > "$DIR/slo.json" 2>/dev/null

  echo "  wrote $DIR" >&2
done

echo "" >&2
echo "  Done. Read it with:  flow show experiment" >&2
