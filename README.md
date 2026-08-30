# Inference Cluster Ops

A single GPU node on GCP running [vLLM](https://github.com/vllm-project/vllm) on
[k3s](https://k3s.io), serving an OpenAI-compatible API. Built to be turned **off**
easily.

```
flow setup cluster        # one-time: quota + tooling checks, terraform init
flow provision cluster    # create everything, install k3s, deploy the workload
flow deploy workloads     # change the model or replica count -- no reboot
flow test chat "hello"    # talk to it
flow show status          # what's on, what it costs
flow stop cluster         # stop paying for compute
```

## Setup

This project uses [flowexec](https://flowexec.io) for workflow documentation and execution.

```sh
brew install kubernetes-cli helm gettext   # kubectl, helm, envsubst run locally
gcloud auth login && gcloud auth application-default login

cp terraform/terraform.tfvars.example terraform/terraform.tfvars
flow show ip                               # prints the allowed_ssh_cidr line
$EDITOR terraform/terraform.tfvars         # set project_id and allowed_ssh_cidr

flow setup cluster                         # quota + tooling checks, terraform init
flow provision cluster                     # create everything, install k3s, deploy
```

Without flow the sequence is `make my-ip`, `make preflight`, `make init`,
`make provision` — the same steps, same scripts. First boot installs the NVIDIA driver,
installs k3s, pulls a multi-GB container and downloads model weights — expect several minutes.

## Architecture

```
GPU VM  (g2-standard-8, 1x L4, spot by default, on/off via desired_status)
│
├── /opt/data  ── persistent disk, survives stop/start AND spot rebuild
│     ├── huggingface/   model weights
│     ├── k3s/           cluster state, rollout history, container images
│     └── storage/       local-path PVCs (Prometheus TSDB, Grafana)
│
└── k3s  (server + agent, single node)
      ├── nvidia-device-plugin   time-slicing -> nvidia.com/gpu: N
      ├── dcgm-exporter          GPU metrics
      ├── argo-rollouts          canary deploys of model versions
      ├── ns: monitoring         Prometheus + Grafana
      └── ns: inference
            ├── Deployment  envoy          static config, NodePort 30800
            ├── Rollout     vllm           N replicas, canary on latency
            └── Services    headless (traffic) + stable/canary (metrics only)

laptop --ssh--> Envoy --> vllm-headless --> all vLLM pods --> L4 (time-sliced)
```

## Using the model

The node has **no inbound opening except port 22, from your address only**. One SSH
session carries everything:

```sh
flow connect kube    # fetch the credential and open the tunnel
```

The tunnel runs in the **background**, so nothing has to hold a terminal open.
`flow test chat`, `flow check health` and `flow open dashboard` each open it for
themselves if it is down, so there is no ordering to remember. `make tunnel` and
`make untunnel` do the same thing.

```sh
flow test chat "Explain tensor parallelism in one sentence."
flow list models
flow check health
```

## Replicas and the GPU

N vLLM pods share one L4 through the device plugin's time-slicing, behind Envoy on
a single endpoint.

```sh
flow scale workers 4
flow show rollout
flow watch gpu
```

## Observability

```sh
flow open dashboard   # Grafana on localhost:3000 -- two dashboards, see below
flow open metrics     # Prometheus on localhost:9090
flow benchmark baseline  # one-shot calibration (inference-perf, as a Job)
flow start load          # sustained two-tenant traffic (inference-perf)
flow stop load
flow show slo         # violations, availability and recovery times
flow show status      # GPU slices, rollout phase, burn rate
flow show pods
```

Prometheus scrapes vLLM, Envoy, dcgm-exporter and the Argo Rollouts controller.
Two dashboards ship as code in [k8s/52-dashboards.yaml](k8s/52-dashboards.yaml):

- **vLLM Serving SLIs** — throughput, latency percentiles, saturation, GPU, errors,
  per-tenant traffic.
- **vLLM Rollout & SLO** — SLO state over time, canary vs stable, recovery.

Everything is computed from recording rules in [k8s/50-prometheus-rules.yaml](k8s/50-prometheus-rules.yaml)
(prefixed `sli:` and `slo:`), so a query lives in one place rather than in every
panel. `sli:vllm:healthy` is the composite objective — the series that makes
"violations" and "recovery time" measurable.

The underlying series worth knowing:

| Metric | Why |
| --- | --- |
| `vllm:time_to_first_token_seconds` | The latency users feel. The canary currently gates on this. |
| `vllm:request_time_per_output_token_seconds` | TPOT — per-request mean decode cost per token |
| `vllm:inter_token_latency_seconds` | ITL — the gap between decode steps. Spikes under contention where TPOT stays smooth |
| `vllm:num_requests_running` / `_waiting` | Queue depth — shows when replicas saturate |
| `vllm:kv_cache_usage_perc` | KV cache pressure — the real ceiling on replica count |
| `DCGM_FI_PROF_GR_ENGINE_ACTIVE` | Real GPU utilization |
| `envoy_cluster_upstream_rq_time_bucket` | End-to-end latency as the client sees it |
| `envoy_vhost_vcluster_upstream_rq` | Per-tenant traffic, keyed on the `x-tenant` header |

### Generating traffic

Both run the same harness, [kubernetes-sigs/inference-perf](https://github.com/kubernetes-sigs/inference-perf) —
one as a Job, one as Deployments. What differs is shape and what you keep:

| | what it is | output |
| --- | --- | --- |
| `flow benchmark baseline` | one-shot; sends N prompts and exits | a report — percentiles and SLO attainment |
| `flow start load` | sustained; runs until stopped | traffic. You read the result in Grafana |

The sustained one runs [kubernetes-sigs/inference-perf](https://github.com/kubernetes-sigs/inference-perf)
as **two tenants at once**, shaped to contend: `batch` sends long prompts whose
prefills occupy the GPU, `interactive` sends short ones and is the tenant you watch
suffer for it.

Defaults sit at roughly half of measured capacity so the cluster stays healthy while
load runs. That is deliberate: a baseline that already violates the SLO leaves a
rollout or a preemption nothing to show. [k8s/config.env](k8s/config.env) documents how to crank it
into deliberate violation.

## Rollout experiments

Observability tells you the fleet is unhealthy. These tell you what a *rollout* did to
it, and let you compare one rollout strategy against another.

```sh
flow run experiment cold-rollout            # A: capacity loss then a cold pod taking traffic
flow run experiment drain                   # B: rejections vs mid-stream truncations
flow run experiment bad-revision            # C: bad deploy w/ rollout analysis
flow run experiment bad-revision ungated    #    the same bad deploy w/o analysis
flow show experiment                        # the most recent run
flow analyze experiments                    # all runs side by side
```

Each run holds the fleet under load, rolls it, pins a measurement window to the
rollout, and writes `runs/<run-id>/`. A scenario is just a set of `k8s/config.env`
overrides in `experiments/<scenario>/<variant>.env` — a new variant needs no new code.

Every scenario deliberately damages a live, billed cluster, so teardown runs from a
trap: an interrupted run still stops the load and restores the baseline revision.

### What each one is for

**cold-rollout** points the new revision's `HF_HOME` at an empty directory, so it must
download and load weights before serving. `maxSurge: 0` is not a choice here — two pods
already use 15.5GB of the L4's 23GB, so a third does not fit — which means the fleet is
at N-1 for the whole download window, and the pod that finally arrives is Ready but
cold. Watch `sli:vllm:requests_running:by_role` next to
`sli:vllm:ttft_seconds:p95:by_role`: Envoy is `LEAST_REQUEST` with no
`slow_start_config`, so a fresh pod with nothing in flight reads as *idle* and gets
preferred at exactly the moment it is slowest.

**drain** rolls with long generations in flight. It counts three things separately,
because they trade against each other: connection-level rejections (retryable and the
retry policy already masks most), mid-stream truncations (**not** retryable — the client
got a 200 and a short answer), and rollout duration. A longer grace period cuts
truncations and lengthens the N-1 window, which is cold-rollout's problem. No single
setting wins both.

**bad-revision** serves with `--max-num-seqs=1`: batching collapses, latency degrades
badly, and nothing crashes — so stock Argo advances on Ready and replaces every replica
with a broken one. The headline is cumulative SLO-violation seconds, gated versus
ungated.
