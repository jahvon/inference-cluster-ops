#!/usr/bin/env bash
# Classify where the node is in its bring-up. Runs ON the node -- piped in over
# ssh with `bash -s`, so it stays a lintable file rather than a quoted heredoc.
#
# Prints exactly one line:
#   READY            serving
#   STAGE <text>     still working, this is normal, keep waiting
#   FAIL <text>      broken; waiting longer will not help
#
# The FAIL cases matter as much as the stages. Under Docker this script's
# predecessor could tell an exited container from a slow one; losing that would
# mean sitting through a 30-minute timeout on a crash-looping pod.
set -uo pipefail

PORT="${ENVOY_NODEPORT:-30800}"
NS=inference
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
K="sudo k3s kubectl"

if ! nvidia-smi >/dev/null 2>&1; then
  echo "STAGE installing GPU driver"; exit 0
fi

if [ ! -f /etc/rancher/k3s/k3s.yaml ] || [ "$($K get --raw /readyz 2>/dev/null)" != "ok" ]; then
  echo "STAGE installing k3s"; exit 0
fi

if ! $K get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; then
  echo "STAGE waiting for node Ready"; exit 0
fi

# No docker-era analogue for this one, and it earns its own stage: 0 here means
# the device plugin could not initialize NVML, i.e. k3s is not running with
# --default-runtime nvidia. That is the single most common k3s+GPU failure, and
# it looks like "pods are pending" unless you name it.
SLICES=$($K get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null)
if [ "${SLICES:-0}" = "0" ] || [ -z "${SLICES:-}" ]; then
  echo "STAGE waiting for GPU device plugin"; exit 0
fi

if ! $K -n $NS get rollout vllm >/dev/null 2>&1; then
  # Not a failure: a cluster with no workload is the state right after a first
  # boot. Say so, rather than letting someone wait out the timeout.
  echo "STAGE awaiting deploy (run 'make deploy')"; exit 0
fi

PODS=$($K -n $NS get pods -l app=vllm -o json 2>/dev/null)

emit_pod_state() {
  echo "$PODS" | python3 -c '
import json, sys
try:
    pods = json.load(sys.stdin).get("items", [])
except Exception:
    print("NONE"); sys.exit(0)
if not pods:
    print("NONE"); sys.exit(0)

waiting, ready, running = [], 0, 0
for p in pods:
    st = p.get("status", {})
    if st.get("phase") == "Pending":
        for c in st.get("conditions", []):
            if c.get("type") == "PodScheduled" and c.get("status") == "False":
                print("UNSCHEDULABLE"); sys.exit(0)
    for cs in st.get("containerStatuses", []):
        w = cs.get("state", {}).get("waiting", {}).get("reason")
        if w: waiting.append(w)
        t = cs.get("lastState", {}).get("terminated", {}).get("reason")
        if t == "OOMKilled": print("OOMKILLED"); sys.exit(0)
        if cs.get("ready"): ready += 1
        if cs.get("state", {}).get("running"): running += 1

for r in waiting:
    if r in ("ErrImagePull", "ImagePullBackOff"): print("IMAGEPULL"); sys.exit(0)
    if r == "CrashLoopBackOff": print("CRASHLOOP"); sys.exit(0)
    if r in ("ContainerCreating", "PodInitializing"): print("CREATING"); sys.exit(0)
print("READY" if ready else ("RUNNING" if running else "PENDING"))
'
}

case "$(emit_pod_state)" in
  NONE)          echo "STAGE waiting for pods to be created"; exit 0 ;;
  UNSCHEDULABLE) echo "STAGE scheduling (waiting for a free GPU slice)"; exit 0 ;;
  IMAGEPULL)
    echo "FAIL image pull"
    $K -n $NS describe pods -l app=vllm 2>/dev/null | grep -A3 -i "failed to pull" | tail -12
    exit 0 ;;
  CRASHLOOP|OOMKILLED)
    echo "FAIL container crashed"
    $K -n $NS logs -l app=vllm --previous --tail=25 2>/dev/null | tail -25
    exit 0 ;;
  CREATING)      echo "STAGE pulling container image"; exit 0 ;;
  PENDING)       echo "STAGE waiting for pods to start"; exit 0 ;;
  RUNNING)
    if $K -n $NS logs -l app=vllm --tail=30 2>/dev/null | grep -qiE "downloading|fetching|resolving data files"; then
      echo "STAGE downloading model weights"
    else
      echo "STAGE loading model into GPU"
    fi
    exit 0 ;;
esac

# Pods are ready. The last hop is the proxy in front of them.
if ! $K -n $NS get deploy envoy -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q '[1-9]'; then
  echo "STAGE waiting for Envoy"; exit 0
fi

if curl -sf -m 5 "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1; then
  echo "READY"
else
  echo "STAGE waiting for Envoy to route"
fi
