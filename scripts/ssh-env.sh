#!/usr/bin/env bash
# Shared plumbing. Sourced, not executed:  . scripts/ssh-env.sh
#
# Provides VM_IP, SSH_USER, SSH_OPTS, require_node, node_ssh, node_scp, and cfg.
#
# VM_IP is read from terraform every time rather than cached, because the
# instance uses an EPHEMERAL external address: it changes on every stop/start. A
# reserved address is the alternative, but it bills while unattached -- exactly
# when this box is stopped, which is most of its life.

if [ -z "${VM_IP:-}" ] || [ -z "${SSH_USER:-}" ]; then
  _tf=$(bash scripts/tf.sh)
  : "${VM_IP:=$(printf '%s\n' "$_tf" | sed -n 's/^VM_IP="\(.*\)"$/\1/p')}"
  : "${SSH_USER:=$(printf '%s\n' "$_tf" | sed -n 's/^SSH_USER="\(.*\)"$/\1/p')}"
  unset _tf
fi
SSH_USER="${SSH_USER:-ops}"

# The private half of terraform's ssh_public_key_path. Deriving it means the key
# is named in exactly one place -- terraform.tfvars -- instead of once for
# terraform and again for every script that connects.
_pub=$(awk -F'"' '/^[[:space:]]*ssh_public_key_path[[:space:]]*=/ {print $2; exit}' \
        terraform/terraform.tfvars 2>/dev/null)
_pub="${_pub:-$HOME/.ssh/id_ed25519.pub}"
_pub="${_pub/#\~/$HOME}"
SSH_KEY="${SSH_KEY:-${_pub%.pub}}"
unset _pub

# accept-new plus a repo-local known_hosts: a recycled ephemeral IP would
# otherwise trip the host-key warning and hang every non-interactive script.
SSH_OPTS=(-i "$SSH_KEY"
          -o StrictHostKeyChecking=accept-new
          -o UserKnownHostsFile=./.ssh_known_hosts
          -o LogLevel=ERROR
          -o ConnectTimeout=10)

require_node() {
  if [ -z "$VM_IP" ]; then
    echo "No VM address. The node is stopped, or nothing has been provisioned yet."
    echo "  make status    what state is it in"
    echo "  make up        start it"
    return 1
  fi
  if [ ! -f "$SSH_KEY" ]; then
    echo "SSH key not found: $SSH_KEY"
    echo "  Set SSH_KEY=, or generate one: ssh-keygen -t ed25519"
    return 1
  fi
}

node_ssh() { ssh "${SSH_OPTS[@]}" "$SSH_USER@$VM_IP" "$@"; }
node_scp() { scp "${SSH_OPTS[@]}" "$@"; }

# One reader for k8s/config.env, so the scripts that need a workload value cannot
# drift in how they parse it:  cfg ENVOY_NODEPORT 30800
cfg() { awk -F= -v k="$1" '$1==k {gsub(/^"|"$/,"",$2); print $2; exit}' k8s/config.env 2>/dev/null | grep . || echo "$2"; }
