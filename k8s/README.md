# k8s/

The portable half of this repo, and the part meant to outlive the GCP experiment.
Everything here runs unmodified against any Kubernetes cluster with an NVIDIA GPU.

```sh
KUBECONFIG=~/.kube/config ./bootstrap.sh
HF_TOKEN=hf_xxx ./bootstrap.sh        # gated models only
./bootstrap.sh --render-only          # render + validate, touch nothing
```

From the repo root, `make deploy` does the same thing against the GCP node: it
fetches the kubeconfig, opens an SSH forward to the API server, and runs this
script. That wrapper is the only GCP-aware code in the deploy path.

## What differs on another cluster

Two things, isolated so each is a one-file change:

**1. The weight cache is a `hostPath`.** `40-vllm-rollout.yaml` mounts
`$HF_CACHE_HOSTPATH` directly off the node, which suits a single-node cluster
whose disk you own. Anywhere else, replace that one volume with a PVC:

```yaml
volumes:
  - name: hf-cache
    persistentVolumeClaim:
      claimName: hf-cache          # ReadWriteMany if pods may land on different nodes
```

**2. `GPU_TIMESLICE_REPLICAS` is sized for one L4.** A different GPU wants a
different number, and a card that supports MIG probably wants MIG instead of
time-slicing. Set it in `config.env`.

## Configuration

`config.env` is the source of truth; a gitignored `config.env.local` overrides it;
and an explicitly-set environment variable beats both, which is how
`make deploy VLLM_REPLICAS=2` works.

`HF_TOKEN` is the one value that is never written to a file. It arrives as an
environment variable and becomes a Kubernetes secret; unset is the normal case,
since the default model is ungated, and the Rollout marks the reference optional
so pods start either way.

The one derived value is `GPU_MEM_UTIL = GPU_MEM_BUDGET / VLLM_REPLICAS`, computed
in `bootstrap.sh`. It matters more than it looks: vLLM's
`--gpu-memory-utilization` is a fraction of **total** VRAM rather than free VRAM,
and GPU time-slicing provides no memory isolation, so that division is the only
thing keeping the pods out of each other's memory.

## Two things that are not obvious

**Model config is substituted into the pod template, not read from a ConfigMap.**
Argo Rollouts only starts a rollout when the pod-template hash changes. A
ConfigMap consumed via `envFrom` would make a model change a silent no-op — no
canary, and pods still running the old weights.

**`bootstrap.sh` applies in an explicit order, not by filename.** The numeric
prefixes are for reading, not sequencing: the Rollout, the ServiceMonitors and
the AnalysisTemplate all need CRDs that arrive via Helm, and the Rollout
additionally waits for the node to actually advertise its GPU slices — capacity
takes 10–30s to refresh after the device plugin restarts, and applying too early
leaves pods Pending in a way that looks exactly like a scheduling bug.

## Dropping Envoy

Envoy is a Deployment and a ConfigMap with no CRDs and no operator, and nothing
else here depends on it. If the target cluster already runs an ingress or a mesh,
delete `20-envoy.yaml` and point that at `vllm-headless` instead.
