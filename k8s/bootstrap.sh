#!/usr/bin/env bash
# Deploy the whole inference stack to whatever cluster KUBECONFIG points at.
#
# Portable by construction: nothing in this directory knows about GCP. The GCP
# wrapper (scripts/deploy.sh) only opens a tunnel and sets KUBECONFIG; on the
# homelab you run this directly.
#
#   ./bootstrap.sh                      deploy
#   ./bootstrap.sh --render-only        render manifests to rendered/ and stop
#
# Set HF_TOKEN in the environment for gated models; it becomes a Kubernetes
# secret. Unset is the normal case -- the default model is ungated.
#
# Idempotent: safe to re-run, and re-running is how you reconfigure. Nothing here
# requires a reboot, which is the entire point of moving off metadata_startup_script.
set -euo pipefail

cd "$(dirname "$0")"

RENDER_ONLY=0
[ "${1:-}" = "--render-only" ] && RENDER_ONLY=1

# --- pinned chart versions --------------------------------------------------
# Pinned so a rebuild reproduces a combination that was known to work. Bumping
# one of these is a deliberate act, not a side effect of the day you deployed.
NVDP_CHART_VERSION=0.17.4
ARGO_ROLLOUTS_CHART_VERSION=2.39.6
KPS_CHART_VERSION=68.3.0

KPS_RELEASE=kps
PROM_SVC_NAME=prometheus-operated

# ---------------------------------------------------------------------------
# 1. Configuration
#
# Precedence, highest first: the environment, then config.env.local, then
# config.env. Expressed by load order -- load_env never overwrites a variable
# that is already set, so whatever is loaded first wins.
#
# config.env is a plain dotenv file rather than a shell script on purpose: flow
# reads it directly with `envFile`, whose parser does not evaluate anything.
# ---------------------------------------------------------------------------
load_env() {
  [ -f "$1" ] || return 0
  while IFS='=' read -r k v; do
    case "$k" in ''|\#*) continue ;; esac
    v="${v%\"}"; v="${v#\"}"
    [ -n "${!k:-}" ] || export "$k=$v"
  done < "$1"
}
load_env ./config.env.local
load_env ./config.env

# ---------------------------------------------------------------------------
# 2. Validation
# ---------------------------------------------------------------------------
for tool in kubectl envsubst; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: $tool not found." >&2
    echo "  macOS: brew install kubernetes-cli helm gettext" >&2
    exit 1
  fi
done
if [ "$RENDER_ONLY" -eq 0 ] && ! command -v helm >/dev/null 2>&1; then
  echo "ERROR: helm not found. brew install helm" >&2
  exit 1
fi

if [ "$GPU_TIMESLICE_REPLICAS" -lt "$VLLM_REPLICAS" ]; then
  echo "ERROR: GPU_TIMESLICE_REPLICAS ($GPU_TIMESLICE_REPLICAS) < VLLM_REPLICAS ($VLLM_REPLICAS)." >&2
  echo "  There would be fewer GPU slices than pods, and the surplus would sit Pending." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 3. Derived values
#
# vLLM's --gpu-memory-utilization is a fraction of TOTAL VRAM, not free VRAM, so
# N pods sharing one GPU must each be told 1/N. Time-slicing gives no memory
# isolation, so nothing else enforces this -- get it wrong and the second pod
# OOMs at load, or takes a healthy one with it.
# ---------------------------------------------------------------------------
GPU_MEM_UTIL=$(awk -v b="$GPU_MEM_BUDGET" -v n="$VLLM_REPLICAS" 'BEGIN{printf "%.4f", b/n}')
export GPU_MEM_UTIL

# Absolute per-pod KV cache. See the long note in config.env: this is what makes
# more than one vLLM pod per GPU possible at all.
KV_CACHE_BYTES=$(awk -v g="$KV_CACHE_GIB" 'BEGIN{printf "%d", g*1024*1024*1024}')
export KV_CACHE_BYTES

# One canary pod, whatever the replica count. Argo rounds up, so this is the
# smallest step that converts exactly one pod.
CANARY_WEIGHT=$(awk -v n="$VLLM_REPLICAS" 'BEGIN{printf "%d", 100/n}')
export CANARY_WEIGHT

export PROM_URL="${PROM_URL:-http://$PROM_SVC_NAME.monitoring:9090}"

echo ""
echo "  model     $MODEL_ID  (served as '$SERVED_MODEL_NAME')"
echo "  image     $VLLM_IMAGE"
echo "  replicas  $VLLM_REPLICAS x ${KV_CACHE_GIB}GiB KV cache each"
echo "  gpu       $GPU_TIMESLICE_REPLICAS time slices of one L4"
echo "  context   $MAX_MODEL_LEN"
echo ""

# ---------------------------------------------------------------------------
# 4. Rendering
#
# The allowlist form of envsubst is mandatory. Bare `envsubst` substitutes EVERY
# $VAR it sees, which silently destroys `$1` in Prometheus relabel replacements
# and ${__interval} / ${DS_PROMETHEUS} in Grafana dashboards -- producing YAML
# that parses fine and does the wrong thing.
# ---------------------------------------------------------------------------
# The allowlist form of envsubst is mandatory. Bare `envsubst` substitutes EVERY
# $VAR it sees, which silently destroys `$1` in Prometheus relabel replacements
# and ${__interval} / ${DS_PROMETHEUS} in Grafana dashboards -- producing YAML
# that parses fine and does the wrong thing.
#
# Derived from config.env's own keys rather than hand-maintained, so adding a
# variable is a one-file change and cannot be half-done.
SUBST_VARS=$(awk -F= '/^[A-Z0-9_]+=/{printf "$%s ", $1}' config.env)
SUBST_VARS="$SUBST_VARS \$GPU_MEM_UTIL \$KV_CACHE_BYTES \$CANARY_WEIGHT \$PROM_URL"  # derived
SUBST_VARS="$SUBST_VARS \$ENVOY_CONFIG_HASH"

ENVOY_CONFIG_HASH="${ENVOY_CONFIG_HASH:-render-only}"
export ENVOY_CONFIG_HASH

# shasum on macOS, sha256sum on Linux -- this script runs on both.
hash_file() { { shasum -a 256 "$1" 2>/dev/null || sha256sum "$1"; } | cut -c1-16; }

MANIFESTS="00-namespace.yaml 10-device-plugin-values.yaml 20-envoy.yaml
35-dcgm-exporter.yaml 40-vllm-rollout.yaml 45-vllm-services.yaml
50-prometheus-rules.yaml 55-servicemonitors.yaml 60-analysis-template.yaml
70-bench-job.yaml 72-load-generator.yaml"

# 70-bench-job.yaml and 72-load-generator.yaml are rendered and validated here but
# NOT applied below: `make deploy` must never start firing traffic at the cluster.
# scripts/calibrate.sh and scripts/load.sh apply the rendered copies on demand.

# Two files are deliberately absent from this list, for the same reason:
#   30-monitoring-values.yaml   helm values, static, and full of Grafana templating
#   52-dashboards.yaml          Grafana dashboard JSON
# Both contain `$__rate_interval`, `${DS_PROMETHEUS}` and friends. The allowlist
# would spare those particular names, but nothing in either file needs substituting,
# so the safest thing is to keep them out of the render path entirely.
DASHBOARDS="52-dashboards.yaml"

RENDERED=rendered
render() { # render <file>  ->  prints rendered/<file>
  mkdir -p "$RENDERED"
  envsubst "$SUBST_VARS" < "$1" > "$RENDERED/$1"
  echo "$RENDERED/$1"
}

if [ "$RENDER_ONLY" -eq 1 ]; then
  rm -rf "$RENDERED"
  for f in $MANIFESTS; do render "$f" >/dev/null; done
  # `kubectl --dry-run=client` still contacts the API server for its schema, so it
  # is no use offline. This checks what can be checked without a cluster: that the
  # YAML parses, that every document is a recognisable object, and -- the failure
  # this is really here for -- that no ${...} survived rendering.
  #
  # It also lifts Envoy's config body out so `make envoy-validate` can hand it to
  # Envoy itself, which is the only real check on that config before it reaches a
  # cluster and crash-loops on a parse error.
  python3 - <<'CHECK'
import pathlib, re, sys, yaml

bad = []
for p in sorted(pathlib.Path("rendered").glob("*.yaml")):
    text = p.read_text()
    for m in re.finditer(r"\$\{[A-Za-z_][A-Za-z0-9_]*\}", text):
        bad.append(f"{p.name}: unsubstituted {m.group(0)}")
    if p.name.endswith("-values.yaml"):
        continue          # helm values, not Kubernetes objects
    for i, doc in enumerate(yaml.safe_load_all(text)):
        if not doc:
            continue
        if p.name == "20-envoy.yaml" and doc.get("kind") == "ConfigMap":
            pathlib.Path("rendered/envoy.yaml").write_text(doc["data"]["envoy.yaml"])
        for k in ("apiVersion", "kind"):
            if k not in doc:
                bad.append(f"{p.name}[{i}]: missing {k}")
        if "name" not in doc.get("metadata", {}):
            bad.append(f"{p.name}[{i}]: missing metadata.name")

if bad:
    print("\n".join("  " + b for b in bad), file=sys.stderr)
    sys.exit(1)
CHECK
  echo "  Rendered $(echo $MANIFESTS | wc -w | tr -d ' ') manifests to k8s/$RENDERED/, all valid."
  echo "  Envoy config at k8s/$RENDERED/envoy.yaml -- check it with 'make envoy-validate'."
  exit 0
fi

# ---------------------------------------------------------------------------
# 5. Apply
#
# Order matters and the numeric filename prefixes cannot express it: the Rollout,
# the ServiceMonitors and the AnalysisTemplate all need CRDs that arrive by helm.
# ---------------------------------------------------------------------------
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin >/dev/null 2>&1 || true
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

echo "==> namespace"
kubectl apply -f "$(render 00-namespace.yaml)"

# The HuggingFace token, if there is one. Only gated models (Llama, Gemma) need
# it, so an empty value is the normal case -- the Rollout marks the reference
# optional so the pod starts either way.
#
# It arrives as an environment variable rather than being read from a cloud
# secret store on the node, which is what keeps this script portable:
#   HF_TOKEN=hf_xxx ./bootstrap.sh
if [ -n "${HF_TOKEN:-}" ]; then
  kubectl -n inference create secret generic hf-token \
    --from-literal=token="$HF_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "    hf-token secret updated"
fi

echo "==> nvidia device plugin (time-slicing x$GPU_TIMESLICE_REPLICAS)"
helm upgrade --install nvdp nvdp/nvidia-device-plugin \
  --version "$NVDP_CHART_VERSION" \
  --namespace kube-system \
  --values "$(render 10-device-plugin-values.yaml)" \
  --wait

# Changing the slice count restarts the plugin, and the node's advertised capacity
# takes 10-30s to catch up. Applying the Rollout before it does leaves pods Pending
# for an interval that looks exactly like a scheduling bug.
#
# This is a hard failure, not a warning. `helm --wait` above is satisfied by a
# DaemonSet with desiredNumberScheduled: 0 -- so a plugin that never schedules at
# all reports a clean install, and the first sign of trouble is four vLLM pods
# Pending on "Insufficient nvidia.com/gpu" long after the deploy said it was done.
echo "==> waiting for the node to advertise $GPU_TIMESLICE_REPLICAS GPU slices"
have=0
for _ in $(seq 1 30); do
  have=$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null)
  [ "${have:-0}" -ge "$GPU_TIMESLICE_REPLICAS" ] 2>/dev/null && break
  sleep 5
done

if ! [ "${have:-0}" -ge "$GPU_TIMESLICE_REPLICAS" ] 2>/dev/null; then
  echo "" >&2
  echo "ERROR: node advertises ${have:-0} GPUs, wanted $GPU_TIMESLICE_REPLICAS." >&2
  echo "  Nothing requesting a GPU can schedule until this is resolved." >&2
  echo "" >&2
  scheduled=$(kubectl -n kube-system get ds nvdp-nvidia-device-plugin \
                -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)
  if [ "${scheduled:-0}" = "0" ]; then
    echo "  The device plugin DaemonSet wants 0 pods, so no node matches it." >&2
    echo "  Its default affinity requires a GPU-discovery label this cluster does" >&2
    echo "  not set. Check that k8s/10-device-plugin-values.yaml still carries" >&2
    echo "    affinity: null" >&2
    echo "  -- note that 'affinity: {}' silently does nothing (helm merges maps)." >&2
  else
    echo "  The plugin pod is scheduled but is not advertising GPUs, which usually" >&2
    echo "  means it could not initialize NVML -- k3s is not using the nvidia" >&2
    echo "  runtime as its default. Check:" >&2
    echo "    kubectl -n kube-system logs -l app.kubernetes.io/name=nvidia-device-plugin" >&2
  fi
  echo "" >&2
  exit 1
fi

echo "==> dcgm-exporter (GPU metrics)"
kubectl apply -f "$(render 35-dcgm-exporter.yaml)"
# The exported field list is a mounted ConfigMap and a ConfigMap change does not
# restart a DaemonSet.
kubectl -n inference rollout restart daemonset/dcgm-exporter
kubectl -n inference rollout status daemonset/dcgm-exporter --timeout=3m

echo "==> kube-prometheus-stack"
helm upgrade --install "$KPS_RELEASE" prometheus-community/kube-prometheus-stack \
  --version "$KPS_CHART_VERSION" \
  --namespace monitoring --create-namespace \
  --values 30-monitoring-values.yaml \
  --wait --timeout 10m

PROM_SVC=$(kubectl -n monitoring get svc "$PROM_SVC_NAME" \
             -o jsonpath='{.metadata.name}' 2>/dev/null || true)
if [ -z "$PROM_SVC" ]; then
  echo "ERROR: no '$PROM_SVC_NAME' service in the monitoring namespace." >&2
  echo "  The canary's latency gate would have nothing to query." >&2
  echo "  Check that kube-prometheus-stack installed:  kubectl -n monitoring get pods" >&2
  exit 1
fi
export PROM_URL="http://$PROM_SVC.monitoring:9090"
echo "    prometheus at $PROM_URL"

echo "==> argo rollouts"
helm upgrade --install argo-rollouts argo/argo-rollouts \
  --version "$ARGO_ROLLOUTS_CHART_VERSION" \
  --namespace argo-rollouts --create-namespace \
  --set controller.metrics.enabled=true \
  --wait

echo "==> envoy"
# Two passes. The first renders with the placeholder hash and is what gets hashed;
# the second carries the real value into the pod-template annotation.
ENVOY_CONFIG_HASH="render-only"   # pass one is always hashed in this known state,
export ENVOY_CONFIG_HASH          # so an inherited value cannot change the result
render 20-envoy.yaml >/dev/null
ENVOY_CONFIG_HASH=$(hash_file "$RENDERED/20-envoy.yaml")
export ENVOY_CONFIG_HASH
kubectl apply -f "$(render 20-envoy.yaml)"
kubectl -n inference rollout status deployment/envoy --timeout=3m

echo "==> vllm"
kubectl apply -f "$(render 45-vllm-services.yaml)"
kubectl apply -f "$(render 60-analysis-template.yaml)"
kubectl apply -f "$(render 40-vllm-rollout.yaml)"
kubectl apply -f "$(render 55-servicemonitors.yaml)"

echo "==> SLI rules and dashboards"
kubectl apply -f "$(render 50-prometheus-rules.yaml)"
for f in $DASHBOARDS; do kubectl apply -f "$f"; done

echo ""
echo "  Deployed. Envoy is on NodePort $ENVOY_NODEPORT."
echo ""
echo "    kubectl argo rollouts get rollout vllm -n inference --watch"
echo "    kubectl port-forward -n monitoring svc/$KPS_RELEASE-grafana 3000:80"
echo ""
echo "  A first rollout downloads weights and can take many minutes."
echo ""
