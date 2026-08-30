#!/usr/bin/env bash
# Managed kubectl port-forwards, the same way scripts/tunnel.sh manages the SSH
# tunnel: backgrounded and idempotent rather than held open in a terminal.
#
#   portfwd.sh grafana ensure    open it if it is not already up
#   portfwd.sh prom close        tear it down
#   portfwd.sh grafana status    is it up
#
# Ports follow the same env overrides as the Makefile: GRAFANA_PORT, PROM_PORT.
set -uo pipefail

NAME="${1:-}"
CMD="${2:-ensure}"

case "$NAME" in
  grafana) NS=monitoring; SVC=svc/kps-grafana;         PORT="${GRAFANA_PORT:-3000}"; TARGET=80 ;;
  prom)    NS=monitoring; SVC=svc/prometheus-operated; PORT="${PROM_PORT:-9090}";    TARGET=9090 ;;
  *)
    echo "usage: portfwd.sh {grafana|prom} {ensure|close|status}" >&2
    exit 1
    ;;
esac

export KUBECONFIG="$PWD/kubeconfig"

# Specific enough that `close` cannot take out an unrelated port-forward the user is
# running against a different service or port.
PATTERN="kubectl.*port-forward.*-n $NS $SVC $PORT:$TARGET"

listening() { (exec 3<>"/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1; }

case "$CMD" in
  ensure)
    # Already up: still print the URL. A second `make dash` should tell you where to
    # go, not silently succeed.
    if listening "$PORT"; then
      echo "  $NAME already on http://localhost:$PORT"
      exit 0
    fi

    # The forward rides the SSH tunnel's :6443, so the API server has to be reachable
    # before kubectl can establish it.
    bash scripts/tunnel.sh ensure >/dev/null || exit 1

    nohup kubectl port-forward -n "$NS" "$SVC" "$PORT:$TARGET" >/dev/null 2>&1 &
    disown 2>/dev/null

    for _ in $(seq 1 30); do
      listening "$PORT" && break
      sleep 0.5
    done

    if listening "$PORT"; then
      echo "  $NAME on http://localhost:$PORT"
    else
      echo "  $NAME port-forward did not come up." >&2
      echo "    kubectl -n $NS get svc ${SVC#svc/}" >&2
      exit 1
    fi
    ;;
  close)
    pkill -f "$PATTERN" 2>/dev/null && echo "  $NAME forward closed." || echo "  no $NAME forward was open."
    ;;
  status)
    if listening "$PORT"; then
      echo "  $NAME up on http://localhost:$PORT"
    else
      echo "  $NAME is down."
      exit 1
    fi
    ;;
  *)
    echo "usage: portfwd.sh {grafana|prom} {ensure|close|status}" >&2
    exit 1
    ;;
esac
