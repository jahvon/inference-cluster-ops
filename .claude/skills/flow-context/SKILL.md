---
name: flow-context
description: This project uses Flow for all development automation. When asked to build, test, run, deploy, lint, generate, or perform any dev task — or to run any one-off shell command — prefer the flow MCP tools over raw Bash so the work runs with the workspace's environment, secrets, and pinned tool versions, and is recorded in Flow's execution history.
user-invocable: false
---

Every dev workflow in this repo is a Flow executable in `.execs/`. The `mcp__flow__*`
tools drive the same platform the `flow` CLI does, with structured JSON in and out —
prefer them over raw `Bash` for anything runnable.

## Running work — pick the closest tool

1. **Named task?** (build, test, lint, validate, generate, deploy, …) →
   `mcp__flow__list_executables` to find it, then `mcp__flow__execute` with
   `executable_verb` (required) plus `executable_id` when it has a name — verb `test` +
   id `unit`, verb `lint` + id `go`. Don't hand-roll a shell command an executable
   already covers.
2. **Arbitrary one-off command?** (a `git …`, a script, an ad-hoc `go run`) →
   `mcp__flow__run_command` with `command` and a short `label`. Preferred over raw
   `Bash`: it runs with workspace env/secrets and lands in `flow logs` with provenance.
   Pass `commands` (array) + `mode` (`serial` | `parallel`) to run several in one call,
   and `dir` to set the working directory.
3. **Richer than one command?** (a serial/parallel batch, an HTTP `request`, a
   `render`/`launch`) → `mcp__flow__run_executable` with an inline `spec` — the same
   shape as one entry under a flowfile's `executables:` list. No file needed.
4. **Fall back to `Bash`** only when a run genuinely shouldn't be recorded, when you need
   CLI flags MCP doesn't expose (`--param`, `--output json`), or for interactive/TTY
   programs.

## Reading output

`mcp__flow__get_execution_logs` returns run metadata (ref, status, exitCode, error) by
default. To see actual output, set one of:

- `tail: <n>` — last N lines. **Best default for debugging** — errors surface at the end.
- `grep: "<regex>"` — only matching lines, applied before `tail`
- `content: true` — full captured output (capped by `max_bytes`, default 50000)

Filters: `last: true` (most recent run), `mine: true` (only what this session launched),
`status` (`running` | `completed` | `failed`), `source` (`cli` | `mcp`), `session`.
Output is read live, so this works on still-running executions too.

## Common executables

**Offline validation**

`generate manifests`, `validate proxy`, `validate terraform`

**Routine mutation**

`deploy workloads`, `scale workers <n>`, `release rollout`, `abort rollout`

**Announce-first** (billed, slow, or degrading)

`start cluster`, `benchmark baseline`, `start load` / `stop load`, `run experiment <scenario>`

Confirm names with `mcp__flow__list_executables` rather than assuming — this list drifts.

## Context & authoring

- `mcp__flow__get_info` — call once at session start. Returns the current
  workspace/namespace/vault plus the docs index (`llms.txt`) and JSON schema URLs.
- `mcp__flow__write_flowfile` — author or edit `.flow` files; validates against the
  schema server-side, so prefer it over writing YAML by hand.
- `mcp__flow__sync_executables` — refresh the cache after adding a `.flow` file.
- Runs are scoped to the workspace containing the working directory; `run_command` and
  `run_executable` accept an optional `workspace` to target another without switching
  the global current workspace.
- Fetch deeper Flow documentation from the URLs `get_info` returns rather than guessing
  at flowfile syntax.
