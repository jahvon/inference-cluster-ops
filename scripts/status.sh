#!/usr/bin/env bash
# Gather everything worth knowing about the node and emit it as JSON.
#
# Data only -- no presentation. `flow show status` renders it through
# k8s/../docs/status.md; `make status` prints it raw. One place where the facts
# are gathered, one place where they are formatted, and no chance of the two
# drifting apart.
set -uo pipefail

PROJECT="${1:-}"
ZONE="${2:-}"
INSTANCE="${3:-inference-node}"

# Both "cannot look" and "nothing there" report the same shape, so the renderer
# only has one absent-case to handle.
not_provisioned() {
  python3 -c 'import json,sys; print(json.dumps({"provisioned": False, "reason": sys.argv[1]}, indent=2))' "$1"
  exit 0
}

if [ -z "$PROJECT" ] || [ -z "$ZONE" ]; then
  not_provisioned "no terraform state and no tfvars -- run make preflight"
fi

JSON=$(gcloud compute instances describe "$INSTANCE" \
  --project "$PROJECT" --zone "$ZONE" --format=json 2>/dev/null)

if [ -z "$JSON" ]; then
  # "no instance" and "not authenticated" both yield empty output here; telling
  # them apart is the difference between a useful message and a wrong one.
  if ! gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | grep -q .; then
    not_provisioned "not authenticated to GCP -- run gcloud auth login && gcloud auth application-default login"
  elif ! gcloud projects describe "$PROJECT" >/dev/null 2>&1; then
    not_provisioned "cannot read project '$PROJECT' -- wrong id, or no access"
  else
    not_provisioned "instance '$INSTANCE' does not exist in $ZONE -- run make provision"
  fi
fi

RATE=$(bash scripts/tf.sh hourly_rate_estimate | grep -oE '[0-9]+\.[0-9]+' | head -1)
IDLE=$(bash scripts/tf.sh idle_monthly_estimate)

# The node half. Everything below the instance describe is derived from it.
NODE_JSON=$(python3 -c '
import json, sys
from datetime import datetime, timezone

d = json.loads(sys.stdin.read())
rate = float(sys.argv[1]) if sys.argv[1] else 0.0
status = d.get("status", "")
started = d.get("lastStartTimestamp", "")

out = {
    "provisioned": True,
    "instance": d.get("name", ""),
    "zone": d.get("zone", "").rsplit("/", 1)[-1],
    "machine_type": d.get("machineType", "").rsplit("/", 1)[-1],
    "provisioning": d.get("scheduling", {}).get("provisioningModel", "STANDARD"),
    "status": status,
    "running": status == "RUNNING",
    "address": (d.get("networkInterfaces") or [{}])[0].get("accessConfigs", [{}])[0].get("natIP", ""),
    "hourly_rate": rate,
    "idle_estimate": sys.argv[2],
}

# A spot VM that stopped on its own was preempted. Worth distinguishing from a
# stop you asked for, since the fix differs (make up vs. nothing).
out["likely_preempted"] = (
    status == "TERMINATED"
    and out["provisioning"] == "SPOT"
    and bool(d.get("lastStopTimestamp"))
)

if status == "RUNNING" and started and rate:
    try:
        t = datetime.fromisoformat(started.replace("Z", "+00:00"))
        hours = (datetime.now(timezone.utc) - t).total_seconds() / 3600
        out["uptime_hours"] = round(hours, 2)
        out["uptime_human"] = "%dh %dm" % (int(hours), int((hours % 1) * 60))
        out["session_cost"] = round(hours * rate, 2)
        out["monthly_if_left_on"] = round(rate * 24 * 30)
    except ValueError:
        pass

print(json.dumps(out))
' "$RATE" "$IDLE" <<< "$JSON")

if ! grep -q '"running": true' <<< "$NODE_JSON"; then
  python3 -m json.tool <<< "$NODE_JSON"
  exit 0
fi

# The cluster half, over one SSH round trip.
. scripts/ssh-env.sh
CLUSTER=$(node_ssh "ENVOY_NODEPORT=$(cfg ENVOY_NODEPORT 30800) bash -s" \
            < scripts/node/cluster-status.sh 2>/dev/null)

python3 -c '
import json, sys
node = json.loads(sys.argv[1])
kv = {}
gpus = []
for line in sys.argv[2].splitlines():
    if "=" not in line:
        continue
    k, _, v = line.partition("=")
    if k == "GPU":
        gpus.append(v)
    else:
        kv[k] = v

if not kv:
    node["cluster"] = {"reachable": False}
else:
    node["cluster"] = {
        "reachable": True,
        "node_ready": kv.get("NODE") == "True",
        # The most diagnostic number on a k3s GPU node: 0 means the device plugin
        # could not initialize NVML, i.e. k3s is not using the nvidia runtime.
        "gpu_slices": int(kv.get("SLICES") or 0),
        "envoy": kv.get("ENVOY", ""),
        "rollout": kv.get("ROLLOUT", ""),
        "serving": kv.get("SERVING") == "ok",
        "model": kv.get("MODEL", ""),
        "gpus": gpus,
    }
print(json.dumps(node, indent=2))
' "$NODE_JSON" "$CLUSTER"
