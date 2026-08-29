#!/usr/bin/env bash
# Emit the node's cluster state as KEY=VALUE lines. Runs ON the node, piped in
# over ssh with `bash -s`, so it stays lintable instead of buried in quoting.
set -uo pipefail

PORT="${ENVOY_NODEPORT:-30800}"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
K="sudo k3s kubectl"

echo "NODE=$($K get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
echo "SLICES=$($K get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null)"
echo "ENVOY=$($K -n inference get deploy envoy -o jsonpath='{.status.readyReplicas}/{.status.replicas}' 2>/dev/null)"
echo "ROLLOUT=$($K -n inference get rollout vllm -o jsonpath='{.status.phase} {.status.readyReplicas}/{.spec.replicas}' 2>/dev/null)"

if curl -sf -m 5 "localhost:$PORT/v1/models" >/dev/null 2>&1; then
  echo "SERVING=ok"
  echo "MODEL=$(curl -s -m 5 "localhost:$PORT/v1/models" 2>/dev/null \
    | tr ',' '\n' | grep -o '"id":"[^"]*"' | head -1 | cut -d: -f2 | tr -d '"')"
else
  echo "SERVING=down"
  echo "MODEL="
fi

nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total \
  --format=csv,noheader 2>/dev/null | sed 's/^/GPU=/'
