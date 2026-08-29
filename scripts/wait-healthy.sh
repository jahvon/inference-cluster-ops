#!/usr/bin/env bash
# First boot installs a GPU driver, installs k3s, pulls a multi-GB image and
# downloads weights, so "slow" and "broken" look identical without progress.
# This distinguishes them -- and, unlike a plain timeout, it gives up early when
# the node reports something waiting cannot fix.
set -uo pipefail

. scripts/ssh-env.sh

TIMEOUT_SECS="${TIMEOUT_SECS:-1800}"
INTERVAL=15

[ -n "$VM_IP" ] || { echo "Not provisioned yet, or the node is stopped."; exit 1; }

echo ""
echo "  Waiting for vLLM on $VM_IP (timeout $((TIMEOUT_SECS / 60))m)."
echo "  First boot installs k3s and downloads the model; later boots restore from"
echo "  the data disk and are much faster."
echo ""

start=$(date +%s)
last=""

while :; do
  elapsed=$(( $(date +%s) - start ))
  if [ "$elapsed" -ge "$TIMEOUT_SECS" ]; then
    echo ""
    echo "  Timed out after $((elapsed / 60))m. The node may still be working."
    echo "  Check: make boot-logs   (disk, driver, k3s install)"
    echo "         make pods        (what the cluster thinks is happening)"
    echo "         make logs        (vLLM startup and weight download)"
    exit 1
  fi

  out=$(node_ssh "ENVOY_NODEPORT=$(cfg ENVOY_NODEPORT 30800) bash -s" \
          < scripts/node/stage.sh 2>/dev/null)

  case "$out" in
    READY*)
      echo ""
      printf '  \033[32mvLLM is serving\033[0m (%dm %ds)\n' $((elapsed / 60)) $((elapsed % 60))
      echo ""
      echo "  flow test chat       say something to it"
      echo "  flow show rollout    the canary's view of the fleet"
      echo "  flow open dashboard  Grafana on localhost:3000"
      echo ""
      exit 0
      ;;
    FAIL*)
      # Waiting longer will not fix this, so stop and show what the node saw.
      echo ""
      printf '\n  \033[31m%s\033[0m\n\n' "${out%%$'\n'*}"
      echo "${out#*$'\n'}" | sed 's/^/    /'
      echo ""
      exit 1
      ;;
    STAGE*)
      stage="${out#STAGE }"
      if [ "$stage" != "$last" ]; then
        printf '\n  [%02d:%02d] %s' $((elapsed / 60)) $((elapsed % 60)) "$stage"
        last="$stage"
      else
        printf '.'
      fi
      ;;
    *)
      # SSH itself not up yet -- normal right after a start.
      if [ "$last" != "booting" ]; then
        printf '\n  [%02d:%02d] waiting for SSH' $((elapsed / 60)) $((elapsed % 60))
        last="booting"
      else
        printf '.'
      fi
      ;;
  esac

  sleep "$INTERVAL"
done
