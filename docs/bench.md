{{ if !data["ok"] }}
# Benchmark failed

{{ data["reason"] }}

    kubectl -n inference logs job/vllm-bench
{{ else }}
# Benchmark

- **Prompts**: {{ string(data["config"]["num_prompts"]) }}
- **Concurrency**: {{ string(data["config"]["concurrency"]) }}
- **Input**: {{ string(data["config"]["input_len"]) }}
- **Output**: {{ string(data["config"]["output_len"]) }}
- **Duration**: {{ string(data["config"]["duration_seconds"]) }}s.

## Throughput

| | |
|---|---|
| **output tokens/s** | **{{ string(data["throughput"]["output_tokens_per_second"]) }}** |
{{ if data["throughput"]["output_tokens_per_second_per_user"] != nil }}| per user (one stream) | {{ string(data["throughput"]["output_tokens_per_second_per_user"]) }} |
{{ end }}| total tokens/s | {{ string(data["throughput"]["total_tokens_per_second"]) }} |
| requests/s | {{ string(data["throughput"]["requests_per_second"]) }} |
| completed | {{ string(data["throughput"]["completed"]) }} |

Per-user throughput here is exact rather than inferred: the client knows how many
streams it had open. The dashboard's live equivalent divides fleet tokens/s by the
number of running requests, which is the same quantity estimated from the server side.

## Latency

| | p50 | p95 | p99 |
|---|---|---|---|
{{ if data["latency"]["ttft"] != nil }}| time to first token | {{ string(data["latency"]["ttft"]["p50"]) }}s | {{ string(data["latency"]["ttft"]["p95"]) }}s | {{ string(data["latency"]["ttft"]["p99"]) }}s |
{{ end }}{{ if data["latency"]["tpot"] != nil }}| time per output token | {{ string(data["latency"]["tpot"]["p50"]) }}s | {{ string(data["latency"]["tpot"]["p95"]) }}s | {{ string(data["latency"]["tpot"]["p99"]) }}s |
{{ end }}{{ if data["latency"]["itl"] != nil }}| inter-token latency | {{ string(data["latency"]["itl"]["p50"]) }}s | {{ string(data["latency"]["itl"]["p95"]) }}s | {{ string(data["latency"]["itl"]["p99"]) }}s |
{{ end }}{{ if data["latency"]["e2el"] != nil }}| end to end | {{ string(data["latency"]["e2el"]["p50"]) }}s | {{ string(data["latency"]["e2el"]["p95"]) }}s | {{ string(data["latency"]["e2el"]["p99"]) }}s |
{{ end }}

{{ if data["slo_attainment"] != nil }}
## SLO attainment

| objective | value | met through |
|---|---|---|
| TTFT p95 | {{ string(data["slo_attainment"]["ttft_objective_seconds"]) }}s | {{ data["slo_attainment"]["ttft_met_through"] }} |
| TPOT p95 | {{ string(data["slo_attainment"]["tpot_objective_seconds"]) }}s | {{ data["slo_attainment"]["tpot_met_through"] }} |

"Met through p99" means at least 99% of requests came in under the objective;
"below p50" means most did not.

This is a bracket, not a goodput ratio. True goodput needs a per-request pass/fail,
and inference-perf only puts aggregates on stdout — its per-request data goes to
report files inside the Job pod, which the pod takes with it when it completes. The
bracket uses the percentiles that were actually measured rather than inventing a
precision that was not.
{{ end }}

{{ if data["errors"] != nil }}
## Errors

{{ string(data["errors"]) }}
{{ end }}

---

Measured with {{ data["harness"] }}, the same harness `flow start load` uses for
sustained traffic — so this number and the one you watch under load share a
definition of TTFT.

Use the p95 figures to set the thresholds in `k8s/config.env`. Those thresholds are
what the canary gate rolls back on, so leave headroom — a threshold at the measured
p95 fails roughly half of all healthy rollouts.
{{ end }}
