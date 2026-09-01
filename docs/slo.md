{{ if !data["available"] }}
# SLO — no data

{{ data["reason"] }}

Check that Prometheus is up and the rules are loaded:

    flow show pods
    flow open metrics      # then search for sli:vllm:healthy
{{ else }}
# SLO — last {{ data["range"]["duration"] }}

{{ data["range"]["from"] }} → {{ data["range"]["to"] }}

| | |
|---|---|
| **availability** | **{{ string(data["slo"]["availability"] * 100) }}%** of {{ string(data["slo"]["samples"]) }} samples |
| time in violation | {{ string(data["slo"]["time_in_violation_seconds"]) }}s |
| incidents | {{ string(data["slo"]["incident_count"]) }} |
{{ if data["recovery"]["count"] > 0 }}| longest recovery | {{ string(data["recovery"]["longest_seconds"]) }}s |
| mean recovery | {{ string(data["recovery"]["mean_seconds"]) }}s |
{{ end }}

{{ if data["slo"]["ongoing"] }}
> **Currently in violation.** The last incident has not recovered, so it is excluded
> from the recovery figures above.
{{ end }}

## Objectives

| | objective | current |
|---|---|---|
| TTFT p95 | {{ string(data["objectives"]["ttft_p95_seconds"]) }}s | {{ string(data["current"]["ttft_p95_seconds"]) }}s |
| TPOT p95 | {{ string(data["objectives"]["tpot_p95_seconds"]) }}s | {{ string(data["current"]["tpot_p95_seconds"]) }}s |
| error ratio | {{ string(data["objectives"]["error_ratio"]) }} | {{ string(data["current"]["error_ratio"]) }} |
{{ if data["objectives"]["truncation_ratio"] != nil }}| truncation ratio | {{ string(data["objectives"]["truncation_ratio"]) }} | {{ string(data["current"]["truncation_ratio"]) }} |
{{ end }}
Objectives come from `k8s/config.env`. The canary gate uses the first three; it
cannot see truncations, which are counted at Envoy's downstream listener and carry
no canary/stable dimension.
{{ if data["capacity"] != nil }}{{ if data["capacity"]["available"] }}
## Serving capacity

| | |
|---|---|
| replicas available / desired | {{ string(data["capacity"]["replicas_available"]) }} / {{ string(data["capacity"]["replicas_desired"]) }} |
| lowest over window | {{ string(data["capacity"]["min_ratio"]) }} |
| time below full | {{ string(data["capacity"]["seconds_below_full"]) }}s |

With `maxSurge: 0` a rollout converts pods rather than adding them, so the fleet
runs below full for the whole replacement window. No latency objective shows that
while the surviving pods still absorb the traffic.
{{ end }}{{ end }}

## Latency

| | p50 | p95 | p99 |
|---|---|---|---|
| time to first token | {{ string(data["current"]["ttft_p50_seconds"]) }}s | {{ string(data["current"]["ttft_p95_seconds"]) }}s | {{ string(data["current"]["ttft_p99_seconds"]) }}s |
| end to end | {{ string(data["current"]["e2e_p50_seconds"]) }}s | {{ string(data["current"]["e2e_p95_seconds"]) }}s | {{ string(data["current"]["e2e_p99_seconds"]) }}s |
| queueing | — | {{ string(data["current"]["queue_p95_seconds"]) }}s | {{ string(data["current"]["queue_p99_seconds"]) }}s |

Time per output token p95 is {{ string(data["current"]["tpot_p95_seconds"]) }}s;
inter-token latency p99 is {{ string(data["current"]["itl_p99_seconds"]) }}s. TPOT is a
per-request mean, ITL is the gap between individual decode steps — under contention ITL
spikes while TPOT stays smooth.

## Throughput and saturation

| | |
|---|---|
| output tokens/s | {{ string(data["current"]["output_tokens_per_second"]) }} |
| per GPU | {{ string(data["current"]["output_tokens_per_gpu"]) }} |
| per in-flight stream | {{ string(data["current"]["output_tokens_per_stream"]) }} |
| requests running | {{ string(data["current"]["requests_running"]) }} |
| requests waiting | {{ string(data["current"]["requests_waiting"]) }} |
| KV cache used | {{ string(data["current"]["kv_cache_usage"]) }} |
{{ if data["current"]["gpu_engine_active"] != nil }}| GPU engine active | {{ string(data["current"]["gpu_engine_active"]) }} |
{{ end }}

"Per in-flight stream" is tokens/s as one concurrent request experiences it. It is not
per tenant — no token counter in this stack carries a tenant label. For an exact
per-client figure, run `flow benchmark baseline`.

{{ if data["current"]["gpu_engine_active"] == nil }}
> GPU engine-active is unavailable, so the only utilization signal is
> `DCGM_FI_DEV_GPU_UTIL` ({{ string(data["current"]["gpu_util_coarse"]) }}), which
> reports whether any kernel was resident rather than how busy the GPU was. With two
> replicas time-slicing one card it sits near 1.0 regardless of real load. See
> `k8s/35-dcgm-exporter.yaml`.
{{ end }}

{{ if len(data["incidents"]) > 0 }}
## Incidents

| start | end | duration | recovered |
|---|---|---|---|
{{ join(map(data["incidents"], "| " + #["start"] + " | " + #["end"] + " | " + string(#["duration_seconds"]) + "s | " + (#["recovered"] ? "yes" : "ongoing") + " |"), "\n") }}

An incident's duration is its recovery time: it opens when the SLI first reads
unhealthy and closes at the first healthy sample.
{{ end }}

{{ if len(data["tenants"]) > 0 }}
## Tenants

| tenant | requests/s |
|---|---|
{{ join(map(data["tenants"], "| " + #["name"] + " | " + string(#["requests_per_second"]) + " |"), "\n") }}

Only tenants declared as virtual clusters in `k8s/20-envoy.yaml` appear here.
{{ end }}
{{ end }}
