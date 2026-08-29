#!/usr/bin/env bash
# Deploy the workload to the node's k3s cluster.
#
# The GCP-aware half of the deploy: fetch the cluster credential, make sure the
# tunnel is up, run k8s/bootstrap.sh against it.
set -uo pipefail

. scripts/ssh-env.sh
require_node || exit 1

# Always refetched, never cached: a spot rebuild gives the cluster a new CA and
# token, and a stale kubeconfig fails in a way that looks like a network problem.
# The retry doubles as the wait for k3s on a freshly created node -- the file does
# not exist until the installer has finished.
#
# k3s writes it mode 644 (--write-kubeconfig-mode in the startup script), so a
# plain scp works, and its server address is already 127.0.0.1:6443, which is
# exactly right through the tunnel.
echo "  fetching kubeconfig from $VM_IP"
for i in $(seq 1 60); do
  node_scp "$SSH_USER@$VM_IP:/etc/rancher/k3s/k3s.yaml" ./kubeconfig 2>/dev/null && break
  [ "$i" = "1" ] && echo "  waiting for k3s to finish installing (first boot takes a few minutes)"
  [ "$i" = "60" ] && {
    echo "  Gave up waiting for k3s. Check 'make boot-logs'."
    exit 1
  }
  sleep 10
done
chmod 600 ./kubeconfig

bash scripts/tunnel.sh ensure || exit 1

# HF_TOKEN passes straight through from the environment. bootstrap.sh turns a
# non-empty value into a Kubernetes secret and ignores an unset one -- which is
# the normal case, since the default model is ungated.
KUBECONFIG="$PWD/kubeconfig" bash k8s/bootstrap.sh
