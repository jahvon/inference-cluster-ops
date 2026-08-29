#!/usr/bin/env bash
# The SSH tunnel, managed rather than held open in a terminal.
#
# Backgrounded (-N -f) deliberately: it is what lets the HTTP executables --
# chat, models, health, the Grafana port-forward -- just work without asking
# anyone to keep a second terminal open. `ensure` is idempotent, so every one of
# them can call it without coordinating.
#
#   tunnel.sh ensure    open it if it is not already up
#   tunnel.sh close     tear it down
#   tunnel.sh status    is it up
set -uo pipefail

. scripts/ssh-env.sh

API_PORT="${API_PORT:-8000}"
K8S_PORT="${K8S_PORT:-6443}"

ENVOY_NODEPORT=$(cfg ENVOY_NODEPORT 30800)

# Matches only the tunnel this repo opens, so `close` cannot take out an
# unrelated ssh session the user has running to the same host.
PATTERN="ssh.*-L $K8S_PORT:127.0.0.1:6443.*-L $API_PORT:127.0.0.1:$ENVOY_NODEPORT"

# bash's /dev/tcp rather than `nc -z`: macOS nc ignores -w on connect and stalls
# for ~8 seconds against an unhealthy listener, which would put that stall in
# front of every executable that checks whether the tunnel is up. A closed
# loopback port refuses instantly, which is the case that actually matters.
listening() { (exec 3<>"/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1; }

case "${1:-ensure}" in
  ensure)
    if listening "$K8S_PORT" && listening "$API_PORT"; then
      exit 0
    fi
    require_node || exit 1
    # A half-open tunnel (one port live, the other not) is worse than none.
    pkill -f "$PATTERN" 2>/dev/null
    ssh "${SSH_OPTS[@]}" "$SSH_USER@$VM_IP" -N -f \
      -L "$K8S_PORT:127.0.0.1:6443" \
      -L "$API_PORT:127.0.0.1:$ENVOY_NODEPORT" || {
        echo "  Could not open the tunnel to $VM_IP."
        echo "  If this hangs or is refused, your address may have changed:"
        echo "    make my-ip    then update allowed_ssh_cidr and re-apply"
        exit 1
      }
    for _ in $(seq 1 20); do
      listening "$K8S_PORT" && listening "$API_PORT" && break
      sleep 0.5
    done
    if listening "$K8S_PORT" && listening "$API_PORT"; then
      echo "  tunnel up: localhost:$K8S_PORT -> kubernetes, localhost:$API_PORT -> vLLM"
    else
      echo "  tunnel did not come up."
      exit 1
    fi
    ;;
  close)
    pkill -f "$PATTERN" 2>/dev/null && echo "  tunnel closed." || echo "  no tunnel was open."
    ;;
  status)
    if listening "$K8S_PORT" && listening "$API_PORT"; then
      echo "  tunnel up: localhost:$K8S_PORT -> kubernetes, localhost:$API_PORT -> vLLM"
    else
      echo "  tunnel is down. Open it with 'make tunnel'."
      exit 1
    fi
    ;;
  *)
    echo "usage: tunnel.sh {ensure|close|status}" >&2
    exit 1
    ;;
esac
