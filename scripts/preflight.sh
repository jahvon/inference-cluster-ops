#!/usr/bin/env bash
# Verifies everything that would otherwise fail late and cryptically at
# `terraform apply` -- GPU quota above all. New GCP projects have 0 GPU quota,
# and spot vs on-demand draw on SEPARATE quotas, which is the usual trap.
set -uo pipefail

PROJECT="${1:-}"
REGION="${2:-us-central1}"

pass=0
fail=0
warn=0

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail + 1)); }
note() { printf '  \033[33m!\033[0m %s\n' "$1"; warn=$((warn + 1)); }
hint() { printf '      %s\n' "$1"; }

echo ""
echo "  Preflight -- project '${PROJECT:-<unset>}', region '$REGION'"
echo ""

# --- tooling ---------------------------------------------------------------
echo "  Tooling"
command -v gcloud >/dev/null 2>&1 && ok "gcloud installed" || bad "gcloud not found"
command -v terraform >/dev/null 2>&1 && ok "terraform installed" || bad "terraform not found"
command -v python3 >/dev/null 2>&1 && ok "python3 installed" || bad "python3 not found"

# The deploy runs kubectl and helm LOCALLY against the node's API server through
# an SSH forward, so these have to be here, not just on the node.
command -v kubectl >/dev/null 2>&1 && ok "kubectl installed" || {
  bad "kubectl not found"; hint "brew install kubernetes-cli"; }
command -v helm >/dev/null 2>&1 && ok "helm installed" || {
  bad "helm not found"; hint "brew install helm"; }
command -v envsubst >/dev/null 2>&1 && ok "envsubst installed" || {
  bad "envsubst not found"; hint "brew install gettext  (keg-only; may need adding to PATH)"; }

# --- access ----------------------------------------------------------------
# Access is plain SSH from one address. Both halves of that fail confusingly at a
# distance -- a missing key looks like a hung boot, and a stale CIDR looks like
# the node never came up -- so check them here instead.
echo ""
echo "  Access"
# shellcheck disable=SC1091
. scripts/ssh-env.sh          # SSH_KEY, derived from terraform.tfvars
if [ -f "$SSH_KEY" ]; then
  ok "ssh key $SSH_KEY"
else
  bad "no ssh key at $SSH_KEY"
  hint "generate one: ssh-keygen -t ed25519"
  hint "or point SSH_KEY / ssh_public_key_path at an existing pair"
fi

ALLOWED=$(awk -F'"' '/^[[:space:]]*allowed_ssh_cidr[[:space:]]*=/ {print $2; exit}' \
  terraform/terraform.tfvars 2>/dev/null)
MYIP=$(curl -sf -m 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')
if [ -z "$ALLOWED" ]; then
  bad "allowed_ssh_cidr is not set in terraform/terraform.tfvars"
  hint "run 'make my-ip' and paste the line it prints"
elif [ -z "$MYIP" ]; then
  note "allowed_ssh_cidr = $ALLOWED (could not determine your current address to compare)"
elif [ "$ALLOWED" = "$MYIP/32" ]; then
  ok "allowed_ssh_cidr matches your address ($MYIP)"
else
  note "allowed_ssh_cidr is $ALLOWED but you are at $MYIP"
  hint "SSH will be refused unless your address falls inside that range."
  hint "'make my-ip' prints the current value; re-apply after changing it."
fi

# --- auth ------------------------------------------------------------------
echo ""
echo "  Auth"
ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -1)
if [ -n "$ACCOUNT" ]; then
  ok "authenticated as $ACCOUNT"
else
  bad "no active gcloud account"
  hint "run: gcloud auth login && gcloud auth application-default login"
fi

if [ -z "$PROJECT" ]; then
  bad "project_id not resolved"
  hint "set project_id in terraform/terraform.tfvars"
elif gcloud projects describe "$PROJECT" >/dev/null 2>&1; then
  ok "project '$PROJECT' reachable"
else
  bad "cannot read project '$PROJECT' (wrong id, or no access)"
fi

# Nothing below can work without auth + project.
if [ -z "$ACCOUNT" ] || [ -z "$PROJECT" ]; then
  echo ""
  echo "  Stopping early: fix auth and project first."
  echo ""
  exit 1
fi

# --- APIs ------------------------------------------------------------------
# Only one API matters, and terraform enables it. It is checked anyway because
# the quota reads below go through it: with compute disabled they return nothing
# and every quota shows as "not reported" rather than as a real number.
echo ""
echo "  APIs"
if gcloud services list --enabled --project "$PROJECT" --format='value(config.name)' 2>/dev/null \
     | grep -q '^compute.googleapis.com$'; then
  ok "compute.googleapis.com"
else
  note "compute.googleapis.com not enabled -- terraform will enable it, but the"
  hint "quota numbers below will read as 'not reported' until it is"
fi

# --- quota -----------------------------------------------------------------
echo ""
echo "  GPU quota -- region $REGION"

REGION_JSON=$(gcloud compute regions describe "$REGION" --project "$PROJECT" --format=json 2>/dev/null)
GLOBAL_JSON=$(gcloud compute project-info describe --project "$PROJECT" --format=json 2>/dev/null)

# Prints "<limit> <usage>" for a metric, or nothing if absent.
read_quota() {
  python3 -c '
import json, sys
try:
    data = json.loads(sys.argv[1] or "{}")
except Exception:
    sys.exit(0)
for q in data.get("quotas", []):
    if q.get("metric") == sys.argv[2]:
        print(int(q.get("limit", 0)), int(q.get("usage", 0)))
        break
' "$1" "$2" 2>/dev/null
}

check_quota() {
  local label="$1" metric="$2" json="$3" need="$4" enables="$5"
  local q limit
  q=$(read_quota "$json" "$metric")
  if [ -z "$q" ]; then
    note "$label: metric not reported (may be unavailable in this region)"
    return
  fi
  limit=$(echo "$q" | awk '{print $1}')
  if [ "$limit" -ge "$need" ]; then
    ok "$label: $limit  -> $enables"
  else
    bad "$label: $limit (need >= $need) -> $enables UNAVAILABLE"
  fi
}

check_quota "PREEMPTIBLE_NVIDIA_L4_GPUS" "PREEMPTIBLE_NVIDIA_L4_GPUS" "$REGION_JSON" 1 "spot (use_spot=true)"
check_quota "NVIDIA_L4_GPUS           " "NVIDIA_L4_GPUS" "$REGION_JSON" 1 "on-demand (use_spot=false)"
check_quota "PREEMPTIBLE_CPUS         " "PREEMPTIBLE_CPUS" "$REGION_JSON" 8 "spot vCPUs for g2-standard-8"
check_quota "CPUS                     " "CPUS" "$REGION_JSON" 8 "on-demand vCPUs for g2-standard-8"

echo ""
echo "  GPU quota -- global"
check_quota "GPUS_ALL_REGIONS         " "GPUS_ALL_REGIONS" "$GLOBAL_JSON" 1 "any GPU anywhere"

# --- verdict ---------------------------------------------------------------
echo ""
if [ "$fail" -gt 0 ]; then
  printf '  \033[31m%d blocking issue(s)\033[0m, %d warning(s)\n' "$fail" "$warn"
  echo ""
  echo "  If the failures are quota: request an increase at"
  echo "    https://console.cloud.google.com/iam-admin/quotas?project=$PROJECT"
  echo "  Filter for 'L4'. You need BOTH a regional GPU quota and the global"
  echo "  'GPUs (all regions)' quota -- one does not imply the other, and spot"
  echo "  and on-demand are separate grants."
  echo ""
  echo "  Justification that gets approved:"
  echo "    Single-node vLLM inference for personal model evaluation."
  echo ""
  echo "  Approval typically takes hours to a couple of days for small L4 asks."
  echo ""
  exit 1
fi

printf '  \033[32mAll %d checks passed\033[0m'"$( [ "$warn" -gt 0 ] && echo ", $warn warning(s)" )"'\n' "$pass"
echo ""
