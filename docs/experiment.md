{{ if !data["ok"] }}
# Experiment — no data

{{ data["reason"] }}

    flow run experiment cold-rollout
    flow run experiment drain
    flow run experiment bad-revision
{{ else }}
# {{ data["meta"]["run_id"] }}

**{{ data["meta"]["scenario"] }}** / {{ data["meta"]["variant"] }} —
rollout ended **{{ data["meta"]["final_phase"] }}** after
{{ string(data["meta"]["duration_seconds"]) }}s,
gate {{ data["meta"]["gated"] ? "enabled" : "REMOVED" }}.
{{ if data["meta"]["timed_out"] }}
> **Timed out.** The rollout never reached a terminal phase, so every number below
> describes an incomplete run.
{{ end }}

## What the client saw

From Envoy's own per-request record — the proxy sees the exchange from outside the
pods, so a pod dying mid-stream cannot take the evidence with it.

| | count | rate |
|---|---|---|
| requests | {{ string(data["requests"]["total"]) }} | |
| completed | {{ string(data["requests"]["complete"]) }} | |
| **truncated** (cut mid-generation) | **{{ string(data["requests"]["truncated"]) }}** | {{ string(data["requests"]["truncation_rate"] * 100) }}% |
| **rejected** (client got an error) | **{{ string(data["requests"]["rejected"]) }}** | {{ string(data["requests"]["rejection_rate"] * 100) }}% |
| retry-masked (client saw a clean 200) | {{ string(data["requests"]["retry_masked"]) }} | |

These three are different kinds of damage, not three views of one.

A **rejection** is retryable, and the retry-masked row is the retry policy doing its
job — those clients never knew. A **truncation** is not retryable *by construction*:
Envoy refuses to retry once response headers have gone downstream, so a stream that
dies at token 200 of 256 reaches the client as a 200 with a short body. No retry
policy repairs it, and no vLLM metric records it — a client-disconnect abort
increments nothing, and the per-request histograms skip aborted requests entirely.

{{ if data["requests"]["truncated_depth_fraction"] != nil }}
Truncated responses carried a median of
{{ string(data["requests"]["median_bytes_truncated"]) }} bytes against
{{ string(data["requests"]["median_bytes_complete"]) }} for a complete one — they died
roughly **{{ string(data["requests"]["truncated_depth_fraction"] * 100) }}%** of the
way through. Bytes rather than tokens, deliberately: it needs no tokenizer and the
ratio is what matters.
{{ end }}

Time to first byte p50 {{ string(data["requests"]["ttfb_p50_seconds"]) }}s,
p95 {{ string(data["requests"]["ttfb_p95_seconds"]) }}s — Envoy's view, the same
source as `sli:envoy:e2e_seconds`.

{{ if len(data["requests"]["by_tenant"]) > 0 }}
### By tenant

| tenant | requests | truncated | rejected |
|---|---|---|---|
{{ join(map(data["requests"]["by_tenant"], "| " + #["name"] + " | " + string(#["total"]) + " | " + string(#["truncated"]) + " | " + string(#["rejected"]) + " |"), "\n") }}
{{ end }}

{{ if len(data["requests"]["by_upstream"]) > 0 }}
### By upstream pod

| pod | requests | truncated | ttfb p95 |
|---|---|---|---|
{{ join(map(data["requests"]["by_upstream"], "| " + #["host"] + " | " + string(#["total"]) + " | " + string(#["truncated"]) + " | " + string(#["ttfb_p95_seconds"]) + "s |"), "\n") }}

The pod that was replaced carries the truncations. A *fresh* pod showing a high
request count next to a poor ttfb p95 is the cold-start problem — it was chosen while
it was still the slowest.
{{ end }}

{{ if len(data["requests"]["detail_classes"]) > 0 }}
### Envoy reset reasons

{{ join(map(data["requests"]["detail_classes"], "- `" + #["name"] + "` x" + string(#["count"])), "\n") }}
{{ end }}

{{ if data["slo"] != nil }}
## SLO over the rollout window

| | |
|---|---|
| **time in violation** | **{{ string(data["slo"]["time_in_violation_seconds"]) }}s** |
| availability | {{ string(data["slo"]["availability"] * 100) }}% of {{ string(data["slo"]["samples"]) }} samples |
| incidents | {{ string(data["slo"]["incident_count"]) }} |

The headline for a gated-versus-ungated comparison. Derived from `sli:vllm:healthy`,
whose inputs are all `rate(...[5m])`, so it lags and smears by up to five minutes —
read it as an order of magnitude, not to the second.

Note one bias when reading TPOT: `vllm:request_time_per_output_token_seconds` is
recorded only when a request *finishes*, so during a drain it describes the survivors.
TTFT does not have this problem — it is recorded when the first token is produced.
{{ if data["slo"]["ongoing"] }}
> **Still in violation** at the end of the window.
{{ end }}
{{ end }}

{{ if data["cold_pod_share"] != nil }}
## Cold-pod share — did the balancer prefer the pod that was warming?

The fresh replica took a mean
**{{ string(data["cold_pod_share"]["mean_share_first_60s"] * 100) }}%**
of in-flight work in its first 60 seconds of serving
({{ string(data["cold_pod_share"]["samples"]) }} samples).

With two replicas an even split is 50%. Envoy is `LEAST_REQUEST` with no
`slow_start_config`, so a pod that has just gone Ready has almost nothing in flight,
reads as idle, and is therefore *preferred* — at exactly the moment it is slowest.
A share at or above 50% is that inversion, measured.
{{ end }}

## Rollout timeline

| time | what |
|---|---|
{{ join(map(data["timeline"], "| " + string(#["ts"]) + " | " + #["kind"] + " " + #["key"] + ": " + string(#["phase"]) + " |"), "\n") }}

---

Window {{ string(data["meta"]["t_start"]) }} → {{ string(data["meta"]["t_end"]) }}.
Compare runs with `flow analyze experiments`.
{{ end }}
