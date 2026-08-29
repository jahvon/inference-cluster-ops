{{ if !data["provisioned"] }}
# Not provisioned

{{ data["reason"] }}
{{ else }}
# {{ data["instance"] }}

| | |
|---|---|
| **status** | {{ data["status"] }}{{ data["running"] ? "" : "  (compute billing stopped)" }} |
| machine | {{ data["machine_type"] }} in {{ data["zone"] }} |
| provisioning | {{ data["provisioning"] }} |
{{ if data["address"] != "" }}| address | `{{ data["address"] }}` — ephemeral, changes on stop/start |
{{ end }}

{{ if data["likely_preempted"] }}
> **Stopped while on SPOT.** If you did not run `flow stop cluster`, this was almost
> certainly a preemption. `flow start cluster` brings it straight back.
{{ end }}

## Cost

{{ if data["running"] }}
| | |
|---|---|
| uptime | {{ data["uptime_human"] }} |
| rate | ${{ string(data["hourly_rate"]) }}/hr |
| **this session** | **${{ string(data["session_cost"]) }}** |
| if left on | ${{ string(data["monthly_if_left_on"]) }}/mo |

`flow stop cluster` drops this to disk cost only.
{{ else }}
Compute is costing nothing. Disks: {{ data["idle_estimate"] }}.
{{ end }}

{{ if data["running"] }}
## Cluster

{{ if !data["cluster"]["reachable"] }}
Unreachable over SSH. Your address may have changed — `flow show ip`, then update
`allowed_ssh_cidr` and re-apply.
{{ else }}
| | |
|---|---|
| k3s node | {{ data["cluster"]["node_ready"] ? "Ready" : "not Ready" }} |
| GPU capacity | {{ string(data["cluster"]["gpu_slices"]) }} time slice(s) |
| envoy | {{ data["cluster"]["envoy"] }} ready |
| rollout | {{ data["cluster"]["rollout"] }} |
| vllm | {{ data["cluster"]["serving"] ? "serving " + data["cluster"]["model"] : "not responding" }} |

{{ if data["cluster"]["gpu_slices"] == 0 }}
> **GPU capacity is 0.** The device plugin cannot initialize NVML, which means k3s
> is not running with `--default-runtime nvidia`. Nothing requesting a GPU will
> schedule until that is fixed. Check `flow show boot-logs`.
{{ end }}

{{ if !data["cluster"]["serving"] }}
> vLLM is not answering. Normal on a first boot while weights download —
> `flow show pods` or `flow show logs` will say which.
{{ end }}

{{ if len(data["cluster"]["gpus"]) > 0 }}
### GPU

{{ join(data["cluster"]["gpus"], "\n\n") }}

vLLM preallocates its KV cache at load, so memory being near-full at idle is
expected rather than a leak. With N replicas you should see N processes, and
their total must stay under the card's capacity — time-slicing will not enforce
that for you.
{{ end }}
{{ end }}
{{ end }}
{{ end }}
