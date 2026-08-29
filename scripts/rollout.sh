#!/usr/bin/env bash
set -uo pipefail

. scripts/ssh-env.sh
require_node || exit 1

CMD="${1:-get}"
shift 2>/dev/null || true

# The plugin binary is invoked directly rather than as `kubectl argo rollouts`:
# that form depends on plugin discovery finding it on PATH, and sudo resets PATH.
RO="sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml /usr/local/bin/kubectl-argo-rollouts -n inference"

case "$CMD" in
  get)     node_ssh -t "$RO get rollout vllm $*" ;;
  promote) node_ssh    "$RO promote vllm $*" ;;
  abort)   node_ssh    "$RO abort vllm" ;;
  *)
    echo "usage: rollout.sh {get|promote|abort} [args]" >&2
    exit 1
    ;;
esac
