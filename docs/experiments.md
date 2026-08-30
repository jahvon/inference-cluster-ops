{{ if !data["ok"] }}
# Experiments — none yet

{{ data["reason"] }}

Each run rolls the fleet under load and measures what the rollout did:

    flow run experiment cold-rollout      # A: capacity loss + a cold pod taking traffic
    flow run experiment drain             # B: rejections vs truncations while draining
    flow run experiment bad-revision      # C: gated
    flow run experiment bad-revision ungated
{{ else }}
# Experiments — {{ string(data["count"]) }} runs

| run | scenario | variant | gate | ended | dur | violation | truncated | rejected | masked |
|---|---|---|---|---|---|---|---|---|---|
{{ join(map(data["runs"], "| " + #["meta"]["run_id"] + " | " + #["meta"]["scenario"] + " | " + #["meta"]["variant"] + " | " + (#["meta"]["gated"] ? "on" : "OFF") + " | " + #["meta"]["final_phase"] + " | " + string(#["meta"]["duration_seconds"]) + "s | " + (#["slo"] != nil ? string(#["slo"]["time_in_violation_seconds"]) + "s" : "--") + " | " + string(#["requests"]["truncated"]) + " | " + string(#["requests"]["rejected"]) + " | " + string(#["requests"]["retry_masked"]) + " |"), "\n") }}

## Reading this

**Violation seconds** is the main measure for Scenario C. Compare a `bad-revision` run
with analysis on against the same run with it off; the gap should be roughly an order
of magnitude.

**Truncated against rejected against masked** is the main measure for Scenario B, and the
three must be read separately. `masked` is the retry policy working — those clients
saw a clean 200. `rejected` is a retry that ran out. `truncated` is damage no retry
can reach: Envoy cannot retry once response headers have gone downstream, so the
client got a 200 and a short answer.

**Duration** is the third axis, and it is in tension with the other two.

## Counting false positives

`good-revision` changes nothing but the nonce, so every one of its rollouts is good by
construction. Any that did not end `Healthy` was halted by the gate on a healthy
fleet:

    EXPERIMENT_REPEAT=10 flow run experiment good-revision

A gate that catches the bad revision but halts a third of good ones is not shippable.
{{ end }}
