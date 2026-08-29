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
flow open dashboard   # Grafana on localhost:3000
flow show status      # GPU slices, rollout phase, burn rate
flow show pods
```

Prometheus scrapes vLLM, Envoy and dcgm-exporter. The series worth building on:

| Metric | Why |
| --- | --- |
| `vllm:time_to_first_token_seconds` | The latency users feel. The canary gates on this. |
| `vllm:num_requests_running` / `_waiting` | Queue depth — shows when replicas saturate |
| `vllm:gpu_cache_usage_perc` | KV cache pressure — the real ceiling on replica count |
| `DCGM_FI_DEV_GPU_UTIL`, `DCGM_FI_DEV_FB_USED` | Whether time-slicing is actually sharing |
| `envoy_cluster_upstream_rq_time_bucket` | End-to-end latency as the client sees it |
