#!/usr/bin/env bash
# Record WHEN things happened during a rollout, as JSONL.
#
# Metric curves alone cannot say whether a TTFT bump began before or after the new
# pod started taking traffic, and that ordering is the whole finding in Scenario A.
# This supplies the ordering; scripts/experiment/report.sh joins the two.
#
#   timeline.sh <outfile>     poll until SIGTERM, appending an event on every change
#
# Emits nothing for a steady state -- only transitions, so the file stays short enough
# to read by eye.
set -uo pipefail

OUT="${1:?usage: timeline.sh <outfile>}"
INTERVAL="${TIMELINE_INTERVAL:-2}"

export KUBECONFIG="${KUBECONFIG:-$PWD/kubeconfig}"

# exec, so the PID run.sh backgrounded IS the poller. Without it $! is this bash
# wrapper, `kill` reaps only the wrapper, and the python child is reparented to init
# and goes on appending to a finished run's timeline for the rest of the session --
# one leaked poller per iteration, each re-polling the cluster over the SSH tunnel.
export OUT INTERVAL
exec python3 - <<'PY'
import json, os, signal, subprocess, sys, time

OUT = os.environ["OUT"]
INTERVAL = float(os.environ["INTERVAL"])

seen = {}


def emit(kind, key, **fields):
    """Append an event only when this key's state actually changed."""
    state = json.dumps(fields, sort_keys=True)
    if seen.get((kind, key)) == state:
        return
    seen[(kind, key)] = state
    rec = {"ts": round(time.time(), 3), "kind": kind, "key": key}
    rec.update(fields)
    with open(OUT, "a") as f:
        f.write(json.dumps(rec, separators=(",", ":")) + "\n")
        f.flush()
        os.fsync(f.fileno())


def poll():
    # One call for all three kinds -- this runs over an SSH tunnel, so a poll that
    # costs three round trips instead of one is three times the tunnel traffic for
    # the entire length of every experiment.
    p = subprocess.run(
        ["kubectl", "-n", "inference", "get", "rollouts,pods,analysisruns",
         "-o", "json"], capture_output=True, text=True)
    if p.returncode != 0:
        return
    try:
        items = json.loads(p.stdout).get("items", [])
    except json.JSONDecodeError:
        return

    for o in items:
        kind = o.get("kind", "")
        md = o.get("metadata", {})
        st = o.get("status", {})
        name = md.get("name", "?")

        if kind == "Rollout":
            emit("rollout", name,
                 phase=st.get("phase"),
                 message=st.get("message"),
                 current_hash=st.get("currentPodHash"),
                 stable_hash=st.get("stableRS"),
                 step=st.get("currentStepIndex"),
                 ready=st.get("readyReplicas"),
                 available=st.get("availableReplicas"),
                 updated=st.get("updatedReplicas"))

        elif kind == "Pod" and md.get("labels", {}).get("app") == "vllm":
            ready = None
            for c in st.get("conditions") or []:
                if c.get("type") == "Ready":
                    ready = c.get("status")
            emit("pod", name,
                 phase=st.get("phase"),
                 ready=ready,
                 hash=md.get("labels", {}).get("rollouts-pod-template-hash"),
                 # Set the moment a drain begins, which is the event Scenario B is
                 # timed against.
                 deleting=bool(md.get("deletionTimestamp")))

        elif kind == "AnalysisRun":
            emit("analysis", name, phase=st.get("phase"), message=st.get("message"))


# run.sh stops this with SIGTERM, whose default disposition kills the process
# without unwinding -- so the `finally` below never runs and the file ends with no
# `stop` event. Routing it to KeyboardInterrupt reuses the path SIGINT already takes.
def on_sigterm(signum, frame):
    raise KeyboardInterrupt


signal.signal(signal.SIGTERM, on_sigterm)

emit("timeline", "start", note="polling began")
try:
    while True:
        poll()
        time.sleep(INTERVAL)
except KeyboardInterrupt:
    pass
finally:
    emit("timeline", "stop", note="polling ended")
PY
