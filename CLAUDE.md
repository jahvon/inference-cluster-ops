# inference-cluster-ops

vLLM serving an OpenAI-compatible API from one GCP G2 (NVIDIA L4) node: k3s,
Envoy, Argo Rollouts, Prometheus/Grafana, driven by `flow` executables in
`.execs/`. See `README.md` for the architecture.

## What this repo is for

**This is a learning platform.** The point is that I understand GPU serving,
rollout safety, and SLO-driven operations — not that the cluster survives
anything. It is a single, temporary, spot-configurable node that I destroy and
rebuild on purpose.

Two consequences, and they govern everything below:

**Explaining is the deliverable.** A correct change I don't understand is a
failed turn. Working code with no reasoning is worth less here than a clear
explanation with a smaller change attached.

**Nothing here needs to be production-ready.** Don't add HA, retries, backup,
RBAC tightening, secret managers, multi-region, or defensive error handling
unless I ask. Don't harden what I'm about to tear down. If you notice a real
production gap, name it in one line and move on — don't fix it. Simple and
legible beats robust.

## How to explain things

For anything architectural, any non-obvious bug, and any change that picks one
approach over another:

- **Explain before you commit to a path.** Lay out what's happening, why, and
  what the options are. Then stop and let me pick. Don't present a decision as
  settled because you already made it.
- **Go deep on mechanism.** I want to know *why* the failure happens — what vLLM,
  Envoy, the device plugin, or the kernel is actually doing — not just which line
  to change. The GPU-sharing comment block in `k8s/config.env` is the depth and
  style I want: the arithmetic, the reason the obvious approach fails, and the
  measured numbers behind the chosen value.
- **Give me 2–3 real alternatives** with the tradeoff that separates them, then
  your recommendation and why. Not a survey of everything possible.
- **Argue against your own recommendation once.** Where would it break, what does
  it cost, what would make me regret it. Honest devil's advocate, one pass, then
  drop it. Don't relitigate after I've chosen and don't manufacture doubt about
  a call that's obviously right.
- **Say when you're unsure.** "I think it's X, here's how we'd confirm" is a good
  answer. Confident wrong guesses cost me a rebuild.

**Don't do this for everything.** Mechanical work — a typo, a rename, a config
value I named, a fix I already described — just do it and say what you did. The
explain-first rule is for decisions, not for keystrokes. If you're unsure which
one you're facing, ask in one sentence rather than writing an essay.

When I'm thinking out loud rather than asking for a change, stay in that mode.
Don't jump to editing files because an idea sounded actionable.

## Running commands: flow first

Every routine operation has a flow executable in `.execs/`. Use it. Reaching for
`make`, `kubectl`, `terraform`, or `scripts/*.sh` directly bypasses the trace of
what was run, which is most of why the executables exist.

1. **Prefer the flow MCP server** when its tools are available — it lists and
   executes the same executables with structured results.
2. Otherwise run `flow <verb> <name>` (or `flow exec <ref>`) through Bash.
3. Only drop to `make`/`kubectl`/`terraform` for something genuinely not covered
   — and say so explicitly when you do.

If you find yourself wanting a raw command more than once, that's a signal a new
executable should exist. Propose it.

### Where logic lives

Flow files hold the interface: verbs, args, descriptions, and short command
lines. Real logic lives in `Makefile` and `scripts/`. When adding something,
follow that split — don't grow shell inside a `.flow` file, and don't add a make
target with no executable in front of it.

The `generate <x>` executables are internal render steps: a script emits JSON,
a `docs/*.md` template formats it. Keep gathering and formatting separated that
way so the two can't drift.

## Cost and destruction

The node is billed while running and this is my money.

- **Never run `flow destroy cluster`.** That's mine to run.
- **Announce before starting anything billed or slow**: `provision cluster`,
  `start cluster`, `run experiment`, `start load`. Then go ahead.
- `flow run experiment` deliberately degrades a live cluster under load. Fine —
  that's the point — but tell me which scenario and what it will do first.
- If work is done and the node is up, remind me `flow stop cluster` exists.

## Verification

- Lint/validate through flow: `flow validate terraform`, `flow generate
  manifests`, `flow validate proxy`. The last two need no cluster.
- Never call something working without having run it. If the cluster is down and
  you can't check, say that instead of implying it passed.
- `k8s/config.env` is the workload's single source of truth. Changes there apply
  with `flow deploy workloads` — no reboot, no terraform.
