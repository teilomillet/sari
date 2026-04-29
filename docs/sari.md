# Sari Runtime Scaffold

Sari is the backend-neutral harness runtime layer for making multiple RS
backends consumable through one operational contract.

Codex is already the reference path because Entr'acte consumes `codex
app-server` today. The first Sari goal is not to refit Codex. The first goal is
to make OpenCode, Claude Code, and future RS backends map to the same runtime
shape.

## Core Boundary

The Elixir core owns:

- session and turn lifecycle
- adapter process ownership
- normalized runtime events
- approval routing
- cancellation and timeout policy
- observability metadata
- deterministic contract tests

Backend adapters own:

- process launch and shutdown
- protocol parsing
- transport-specific streaming
- backend-specific approval semantics
- mapping backend events to `Sari.RuntimeEvent`
- explicit unsupported or degraded capability declarations

## Current Modules

- `Sari.RuntimeBackend`: behaviour every adapter implements.
- `Sari.Runtime`: backend-neutral entry points.
- `Sari.RuntimeCapabilities`: explicit support/degradation/unsupported map.
- `Sari.RuntimeEvent`: normalized event envelope.
- `Sari.Backend.Fake`: deterministic backend for core tests.
- `Sari.AppServer.Protocol`: bounded Entr'acte-compatible JSON-RPC state
  machine.
- `Sari.CLI`: minimal `sari app-server` stdin/stdout wrapper around the
  protocol state machine.
- `Sari.Backend.OpenCodeHttp`: HTTP/SSE adapter for `opencode serve`.
- `Sari.Backend.ClaudeCodeStreamJson`: one-shot subprocess adapter for Claude
  Code `stream-json`.
- `Sari.EntracteContract`: bounded app-server surface Entr'acte currently
  needs.

## Next Implementation Slices

1. Re-run the real OpenCode and Claude Code probes after Entr'acte PR #2 lands.
2. Configure Entr'acte's `app_server` command to launch Sari instead of Codex.
3. Add a resident Claude Code session mode once Sari grows an explicit
   `stop_session` backend callback.
4. Add approval routing through Claude Code `--permission-prompt-tool` and MCP.
5. Run the Sari app-server facade under Entr'acte's existing command slot in a
   disposable workflow.

## Scaling Rule

Use USL for concurrency decisions. Treat `N` as concurrent sessions or backend
processes, `sigma` as shared-resource contention, and `kappa` as coherency cost
from cross-session synchronization. Keep defaults conservative until measured
steady-state data shows the peak.

Run the current app-server/fake-backend profile with:

```bash
mix sari.profile --concurrency 1,2,4,8,16 --iterations 100
```

Probe the local OpenCode server surface with:

```bash
mix sari.profile --scenario opencode_probe
```

To explicitly test the async prompt path, pass a prompt:

```bash
mix sari.profile --scenario opencode_probe --prompt "hello"
```

The task emits markdown by default and JSON with `--format json`. The
`app_server_fake` scenario measures:

- bounded app-server protocol handling
- native JSON decode/encode
- fake backend session/turn execution
- normalized event emission
- concurrent workers over configurable `N`

Recorded fields include throughput, p50/p95 latency, reductions per operation,
memory delta, mailbox delta, output message count, and errors.

The `opencode_probe` scenario starts `opencode serve`, waits for
`/global/health`, measures cold start, then records endpoint timings for
`/global/health`, `/doc`, and `/session`. It also opens `/global/event` long
enough to record first SSE bytes and performs a minimal session lifecycle:
create a session, list its messages, check `/session/status`, and delete the
session. Prompt submission is opt-in because it may depend on auth, model, and
provider configuration. Treat first-run database migrations as separate
evidence from steady-state startup measurements.

The `claude_code_probe` scenario verifies the local `claude` executable and
version without making a model call by default:

```bash
mix sari.profile --scenario claude_code_probe
```

To explicitly spend a Claude Code turn through Sari's adapter, pass a prompt:

```bash
mix sari.profile --scenario claude_code_probe --prompt "Reply exactly: sari-claude-ok"
```

This records version latency, session setup latency, turn duration, event count,
assistant text, final terminal event, token usage, and cost when Claude Code
reports it.

The local checked CLI was `2.1.92 (Claude Code)`. In the sandboxed command
environment, `claude auth status --text` could not see the login state. Running
outside the sandbox reported the Claude Max account login correctly.

Verified real Claude Code output on 2026-04-29 included:

- direct Sari Claude probe assistant text: `sari-claude-real-ok`
- direct Sari Claude probe terminal event: `turn_completed`
- direct Sari Claude probe elapsed time: `2088 ms`
- direct Sari Claude probe reported cost: `0.0240602 USD`
- Entr'acte PR #2 app-server smoke backend: `claude_code_stream_json`
- Entr'acte PR #2 app-server smoke assistant text:
  `sari-claude-app-server-ok`
- Entr'acte PR #2 app-server smoke terminal event: `turn_completed`
- Entr'acte PR #2 app-server smoke elapsed time: `2380 ms`

## OpenCode With LM Studio

The project-local [opencode.lmstudio.json](../opencode.lmstudio.json) config
declares LM Studio as an OpenAI-compatible OpenCode provider:

- provider id: `lmstudio`
- model: `lmstudio/google/gemma-4-e4b`
- base URL: `http://127.0.0.1:1234/v1`

For the current OpenCode system prompt, LM Studio must load the model with more
than the default `4096` context. The verified local run used `8192`:

```bash
lms server start --port 1234 --bind 127.0.0.1
lms unload google/gemma-4-e4b
lms load google/gemma-4-e4b --context-length 8192 --identifier google/gemma-4-e4b --parallel 1 -y
```

Then start OpenCode with the LM Studio config:

```bash
OPENCODE_CONFIG=$PWD/opencode.lmstudio.json \
  opencode serve --hostname 127.0.0.1 --port 41887
```

Drive the real OpenCode HTTP adapter through Sari:

```bash
SARI_OPENCODE_BASE_URL=http://127.0.0.1:41887 \
  mix run scripts/sari_opencode_lmstudio_probe.exs
```

Verified output on 2026-04-29 included:

- `assistant_delta`: `sari-adapter-ok`
- `token_usage`: input `7086`, output `7`, total `7093`
- terminal event: `turn_completed`
- elapsed time: `16689 ms`

## Entr'acte Runtime Compatibility

`teilomillet/entracte#2` has landed. The merged runtime surface keeps
`agent.runner=app_server` for JSON-RPC stdio app-server processes and adds
`agent.runner=headless` for plain commands. Sari should plug into the
`app_server` path because that path preserves streaming notifications,
approvals, dynamic tools, token usage, and terminal turn events. The `headless`
runner is useful for command-style CLIs, but it collapses the runtime to process
output and exit status.

Entr'acte launches the app-server command from the issue workspace, so Sari ships
`scripts/sari_app_server` as a repo-root wrapper. The wrapper changes back to the
Sari repository, compiles quietly when needed, and starts `Sari.CLI` on stdin and
stdout.

Configure Sari as the merged Entr'acte app-server command:

```yaml
agent:
  runner: app_server
codex:
  command: /Users/teilomillet/Code/sari/scripts/sari_app_server --backend fake
```

OpenCode through Sari:

```yaml
agent:
  runner: app_server
codex:
  command: SARI_BACKEND=opencode_http SARI_OPENCODE_BASE_URL=http://127.0.0.1:41888 /Users/teilomillet/Code/sari/scripts/sari_app_server
```

Claude Code through Sari:

```yaml
agent:
  runner: app_server
codex:
  command: SARI_BACKEND=claude_code_stream_json /Users/teilomillet/Code/sari/scripts/sari_app_server
```

For a repeatable local smoke, start OpenCode with LM Studio and run the merged
Entr'acte request sequence against Sari app-server:

```bash
OPENCODE_CONFIG=$PWD/opencode.lmstudio.json \
  opencode serve --hostname 127.0.0.1 --port 41888

SARI_OPENCODE_BASE_URL=http://127.0.0.1:41888 \
  mix run scripts/sari_app_server_entracte_pr2_smoke.exs
```

Run the same request sequence against Claude Code:

```bash
SARI_BACKEND=claude_code_stream_json \
SARI_ENTRACTE_PROMPT="Reply exactly: sari-claude-ok" \
  mix run scripts/sari_app_server_entracte_pr2_smoke.exs
```

Entr'acte now has a regression test proving the merged app-server runner accepts
a Sari-compatible command through `codex.command` and receives Sari thread,
turn, token-usage, and terminal notifications.

Verified output on 2026-04-29:

- `initialize_backend`: `opencode_http`
- methods: `response`, `turn/started`, `item/agentMessage/delta`,
  `thread/tokenUsage/updated`, `turn/completed`
- assistant text: `sari-app-server-ok`
- token usage: input `7088`, output `9`, total `7097`
- elapsed time: `1297 ms`

## Contract Fixtures And Capability Matrix


Sari now pins the app-server facade with golden JSONL fixtures under
`test/fixtures/app_server_contract`. The fixtures cover the stable consumer
surface we need before plugging deeper into Entr'acte:

- initialize and initialized handshake
- thread start
- turn start
- assistant deltas
- token usage
- terminal completion
- fail-closed unknown-thread errors
- tool events, approval requests, and cancellation

Run only those fixtures with:

```bash
mix test test/sari/app_server_contract_fixture_test.exs
```

The backend matrix is generated from the backend declarations plus the external
Codex app-server reference row:

```bash
mix sari.capabilities
mix sari.capabilities --format json
```

The matrix answers the concrete Entr'acte questions for each backend:
streaming, tool calls, approval requests, token usage, cost, resume, cancel,
workspace mode, and context-limit handling. `codex_app_server` is intentionally
marked as `implemented: false` in Sari because it is the external compatibility
reference Entr'acte already consumes, not a Sari adapter we need to refit now.

## Backend Hardening

Sari has a fail-fast prompt budget guard. It only blocks a turn when a context
limit is configured, because exact model limits are deployment-specific for LM
Studio/OpenCode and model-specific for Claude Code. The estimate is conservative
and local: roughly one token per four UTF-8 bytes plus structure overhead.

App-server CLI examples:

```bash
mix run -e 'Sari.CLI.main(["app-server", "--backend", "opencode_http", "--context-limit", "8192", "--reserved-output-tokens", "512"])'

mix run -e 'Sari.CLI.main(["app-server", "--backend", "claude_code_stream_json", "--context-limit", "200000", "--reserved-output-tokens", "1024"])'
```

OpenCode turns now have both per-event and whole-turn timeout policy, and failed
turn events use the normalized Sari error envelope. Claude Code turns redirect
stderr away from JSONL stdout, include stderr excerpts on process failures, and
clean up active turn state and stderr temp files on success, failure, timeout,
or interruption.

## Backend Sweep Profiling

Use `backend_sweep` for USL-ready repeated measurements that include startup,
first assistant token, full turn, memory delta, reductions, concurrency, and
failure rate:

```bash
mix sari.profile --scenario backend_sweep --backend fake --concurrency 1,2,4,8 --iterations 100
```

Real backend sweeps are opt-in because they can spend model tokens:

```bash
SARI_OPENCODE_BASE_URL=http://127.0.0.1:41888 \
  mix sari.profile --scenario backend_sweep --backend opencode_http \
  --context-limit 8192 --reserved-output-tokens 512 --iterations 1

mix sari.profile --scenario backend_sweep --backend claude_code_stream_json \
  --context-limit 200000 --reserved-output-tokens 1024 --iterations 1
```

Interpretation rule: use the fake backend for Sari core overhead, OpenCode for
HTTP/SSE server behavior, and Claude Code for subprocess JSONL behavior. Do not
compare those numbers as if they measure the same bottleneck; they isolate
different parts of the stack.
