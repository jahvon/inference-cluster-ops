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

{{ if data["goodput"] != nil }}
## Goodput

**{{ string(data["goodput"]["percentage_of_all_sent"]) }}%** of everything sent came
back both successful *and* within SLO —
{{ string(data["goodput"]["good_requests"]) }} of
{{ string(data["goodput"]["total_requests"]) }} successful requests met every
constraint, and {{ string(data["goodput"]["success_ratio"] * 100) }}% of requests
succeeded at all.

| | |
|---|---|
| **goodput (of all sent)** | **{{ string(data["goodput"]["percentage_of_all_sent"]) }}%** |
| of successful requests only | {{ string(data["goodput"]["percentage_of_successful"]) }}% |
| good requests/s | {{ string(data["goodput"]["request_goodput_per_second"]) }} |
| good output tokens/s | {{ string(data["goodput"]["token_goodput_per_second"]) }} |

Constraints: TTFT ≤ {{ string(data["goodput"]["constraints"]["ttft_seconds"]) }}s,
TPOT ≤ {{ string(data["goodput"]["constraints"]["tpot_seconds"]) }}s. These are the
same numbers in `k8s/config.env` that drive `sli:vllm:healthy` and the canary gate, so
"met SLO" means one thing here, on the dashboards, and in the gate. A request passes
only if it met *every* constraint.

{{ if len(data["goodput"]["attainment_percentage"]) > 0 }}
Which objective the misses missed:

{{ join(map(data["goodput"]["attainment_percentage"], "- " + #["name"] + ": " + string(#["percentage"]) + "% met"), "\n") }}
{{ end }}

The two percentages differ on purpose. inference-perf divides by *successful* requests,
so on its own it answers "of the requests that came back, how many were fast enough" —
a run where most requests errored and the survivors were quick would report near 100%.
The headline multiplies that by the success ratio, which is the number a user would
recognise: of everything asked for, how much arrived correct and on time.

Use goodput rather than the p95 figures when deciding whether a change helped. A p95
can improve while goodput falls, if the change shifted mass from just-under the
objective to just-over it.
{{ end }}

{{ if data["slo_attainment"] != nil }}
## SLO attainment (percentile bracket)

| objective | value | met through |
|---|---|---|
| TTFT p95 | {{ string(data["slo_attainment"]["ttft_objective_seconds"]) }}s | {{ data["slo_attainment"]["ttft_met_through"] }} |
| TPOT p95 | {{ string(data["slo_attainment"]["tpot_objective_seconds"]) }}s | {{ data["slo_attainment"]["tpot_met_through"] }} |

"Met through p99" means at least 99% of requests came in under the objective;
"below p50" means most did not. A coarse bracket kept as a fallback — the goodput
figures above are a real per-request pass/fail and supersede it whenever they are
present.
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
