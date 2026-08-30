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
  tfval() { printf '%s\n' "$_tf" | sed -n "s/^$1=\"\(.*\)\"$/\\1/p"; }
  : "${VM_IP:=$(tfval VM_IP)}"
  : "${SSH_USER:=$(tfval SSH_USER)}"

  # Terraform's state lags the live instance after a stop/start: the external
  # address is ephemeral and the provider does not always re-read it in the same
  # apply that sets desired_status.
  #
  # Ask GCP directly, then RESYNC STATE so this path is taken once per drift
  # rather than on every invocation. -refresh-only reads infrastructure and
  # updates state; it changes nothing and creates nothing.
  if [ -z "$VM_IP" ]; then
    _proj=$(tfval PROJECT_ID); _zone=$(tfval ZONE); _inst=$(tfval INSTANCE_NAME)
    if [ -n "$_proj" ] && [ -n "$_zone" ]; then
      VM_IP=$(gcloud compute instances describe "${_inst:-inference-node}" \
                --project "$_proj" --zone "$_zone" \
                --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || true)
      if [ -n "$VM_IP" ]; then
        echo "  terraform state was stale; resyncing ($VM_IP)" >&2
        # Synchronous, once per drift: ~10s here buys correct state for every
        # command after it. Backgrounding would race a short-lived caller like
        # `make ssh` exiting before the refresh lands. Terraform's own state
        # lock handles the concurrent case, and a failure is not fatal -- VM_IP
        # is already correct for this run regardless.
        terraform -chdir=terraform apply -refresh-only -auto-approve \
          -var running=true >/dev/null 2>&1 || true
      fi
    fi
    unset _proj _zone _inst
  fi
  unset _tf
  unset -f tfval
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
