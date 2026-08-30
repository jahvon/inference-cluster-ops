#!/usr/bin/env bash
# Start and stop sustained multi-tenant load.
#
#   load.sh start     apply the generators and wait until traffic is flowing
#   load.sh stop      delete them
#   load.sh status    are they running, and what is each tenant sending
#
# Unlike scripts/calibrate.sh this produces no report. It holds
# the cluster under traffic so the SLO, the canary and the per-tenant panels have
# something to measure and you read the result in Grafana or `flow show slo`.
set -uo pipefail

. scripts/ssh-env.sh
require_node || exit 1

bash scripts/tunnel.sh ensure >/dev/null || exit 1

export KUBECONFIG="$PWD/kubeconfig"

CMD="${1:-start}"

case "$CMD" in
  start)
    bash k8s/bootstrap.sh --render-only >/dev/null 2>&1 || {
      echo "  Could not render manifests. Run 'make render' to see why." >&2
      exit 1
    }
    MANIFEST=k8s/rendered/72-load-generator.yaml
    [ -f "$MANIFEST" ] || { echo "  $MANIFEST missing after render." >&2; exit 1; }

    kubectl apply -f "$MANIFEST" >/dev/null || {
      echo "  Could not apply the load generators." >&2
      exit 1
    }

    kubectl -n inference rollout restart \
      deployment/load-interactive deployment/load-batch >/dev/null 2>&1

    echo "  starting load generators..."
    for d in load-interactive load-batch; do
      kubectl -n inference rollout status "deployment/$d" --timeout=5m >/dev/null 2>&1 || {
        echo "" >&2
        echo "  $d did not become ready. Recent output:" >&2
        kubectl -n inference logs "deployment/$d" --tail=25 2>/dev/null | sed 's/^/    /' >&2
        echo "" >&2
        echo "  Full output:  kubectl -n inference logs deployment/$d" >&2
        exit 1
      }
    done

    # Ready is not the same as sending. A crash on a bad config, an unreachable
    # tokenizer or a rejected header all leave a Running pod that never issues a
    # request, and the only visible symptom is a dashboard that stays flat.
    echo "  waiting for traffic to reach Envoy..."
    # A RATE over the two tenants this script starts, not a total over all of them.
    Q='sum(rate(envoy_vhost_vcluster_upstream_rq{envoy_virtual_host="vllm",envoy_virtual_cluster=~"interactive|batch"}[1m]))'
    URL="/api/v1/namespaces/monitoring/services/prometheus-operated:9090/proxy/api/v1/query"
    for _ in $(seq 1 24); do
      N=$(kubectl get --raw "$URL?query=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$Q")" 2>/dev/null \
          | python3 -c 'import json,sys
try:
    r = json.load(sys.stdin)["data"]["result"]
    print(float(r[0]["value"][1]) if r else 0)
except Exception:
    print(0)')
      case "$N" in 0|0.0) ;; *) break ;; esac
      sleep 5
    done

    echo ""
    bash scripts/load.sh status
    ;;

  stop)
    kubectl -n inference delete deployment load-interactive load-batch \
      --ignore-not-found >/dev/null 2>&1
    echo "  load generators stopped."
    ;;

  status)
    RUNNING=$(kubectl -n inference get deploy -l app=load-generator \
                -o jsonpath='{range .items[*]}{.metadata.labels.tenant}{"="}{.status.readyReplicas}{"\n"}{end}' 2>/dev/null)
    if [ -z "$RUNNING" ]; then
      echo "  no load generators running.  'flow start load' to begin."
      exit 1
    fi
    printf '%s\n' "$RUNNING" | while IFS='=' read -r t r; do
      [ -n "$t" ] && echo "  tenant $t: ${r:-0} replica(s) ready"
    done
    echo ""
    echo "  watch it:   flow open dashboard      (vLLM Serving SLIs -> per-tenant panels)"
    echo "              flow show slo            (violations and recovery)"
    echo "  stop it:    flow stop load"
    ;;

  *)
    echo "usage: load.sh {start|stop|status}" >&2
    exit 1
    ;;
esac
