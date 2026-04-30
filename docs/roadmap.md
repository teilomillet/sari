# Sari Roadmap

This document maps Sari's current state to what needs to happen next. It is a
priority map grounded in the existing capability declarations, conformance tests,
and the Entr'acte operational contract, not a dated release plan.

The basis for every item is the evidence already in this repository:
`README.md`, `docs/sari.md`, `WORKFLOW.md`, the runtime capability matrix, and
the Entr'acte-compatible protocol fixtures.

---

## Delivered

What is complete and verified as of the current HEAD.

| Item | Key evidence |
|---|---|
| Core runtime - session, turn, event normalization | `Sari.Runtime`, `Sari.RuntimeEvent`, `Sari.Session`, `Sari.Turn` |
| Capability declaration and conformance suite | `Sari.RuntimeCapabilities`; `mix test test/sari/runtime_conformance_test.exs` |
| Fake backend - all 15 capabilities, deterministic | `Sari.Backend.Fake` |
| OpenCode HTTP/SSE adapter | `Sari.Backend.OpenCodeHttp`; verified with LM Studio on 2026-04-29 |
| Claude Code stream-json adapter | `Sari.Backend.ClaudeCodeStreamJson`; real turn verified on 2026-04-29 (2088 ms, 0.024 USD) |
| App-server protocol facade | `Sari.AppServer.Protocol`; bounded Codex-compatible JSON-RPC surface |
| Entr'acte dynamic tool bridge | `Sari.Mcp.EntracteTools` - `linear_graphql` and `gitlab_coverage` via local MCP |
| App-server contract fixtures | `test/fixtures/app_server_contract`; JSONL covering initialize, thread, turn, tool, approval, cancel |
| Capability matrix CLI | `mix sari.capabilities` |
| Runtime preset registry | `mix sari.presets`; `fake`, `opencode_lmstudio`, `claude_code` presets |
| Profiling infrastructure | `mix sari.profile`; `app_server_fake`, `opencode_probe`, `claude_code_probe`, `backend_sweep` |
| Backend hardening | Prompt budget guard, per-event and whole-turn timeouts, stderr isolation, normalized error envelopes |
| Entr'acte PR #2 integration | `app_server` runner verified end-to-end: OpenCode 1297 ms, Claude Code 2380 ms, both terminal `turn_completed` |

---

## Must-have

These items block Sari replacing Codex as the default Entr'acte backend or block
operating without unsafe defaults.

### `stop_session` backend callback

**Why**: `RuntimeBackend` has no explicit session termination. Claude Code therefore
runs one subprocess per turn with no clean shutdown path, which makes resident
session mode impossible and leaves open processes on crash.

**Done when**:
- `stop_session/1` is added to the `RuntimeBackend` behaviour with a documented
  required vs optional contract.
- `Fake`, `ClaudeCodeStreamJson`, and `OpenCodeHttp` implement it.
- `OpenCodeHttp` maps it to `DELETE /session/:id`.
- Conformance suite verifies every registered backend declares the callback.

### Resident Claude Code session mode

**Why**: One subprocess per turn means each Entr'acte continuation turn cold-starts
a fresh Claude Code process. Context is lost between turns and first-token latency
is paid every time.

**Done when**:
- `ClaudeCodeStreamJson` can hold an open process between turns within a session.
- Resume (`--resume --session-id`) works correctly in the resident path.
- `stop_session` cleanly terminates the resident process.
- `:resume` capability upgraded from degraded to supported.
- `backend_sweep` shows measurable latency improvement from turn 2 onward.

**Prerequisite**: `stop_session` callback.

### Full approval round-trip for Claude Code

**Why**: Claude Code currently runs with `--dangerously-skip-permissions`. Entr'acte
cannot gate file writes, command execution, or tool calls without a real
approve/reject round-trip through Sari.

**Done when**:
- `ClaudeCodeStreamJson` launches with `--permission-prompt-tool` pointing to a
  Sari-owned MCP tool.
- Sari routes the pending approval to `Sari.ApprovalRequest` and emits it as
  `:approval_requested` in the event stream.
- Entr'acte sends approve or reject; Sari forwards the response to the MCP tool
  server and Claude Code proceeds accordingly.
- `:approvals` and `:approval_requests` capabilities upgraded from degraded to
  supported.
- Contract fixture covers the full approve/reject round-trip.

### Neutral Entr'acte configuration key

**Why**: `codex.command` in WORKFLOW.md leaks Codex as an implementation detail.
Operators switching to Sari cannot distinguish Codex-specific from Sari-compatible
configuration.

**Done when**:
- Entr'acte accepts `runtime.command` or `sari.command` alongside `codex.command`.
- Old `codex.command` configurations continue to work (backward-compat shim).
- WORKFLOW.md and README show `runtime.command` as the recommended path.
- `mix sari.presets --format workflow` emits the neutral key.

### Verified end-to-end Entr'acte run with Claude Code

**Why**: Current verification used a standalone smoke script. A real Entr'acte
runner picking up a Linear ticket through the Claude Code preset is the only proof
that the full operational path works: ticket pickup, tool injection, turn completion,
and issue state transition.

**Done when**:
- A Sari workspace runner is configured with the `claude_code` preset.
- A test ticket tagged `agent-ready` is picked up and completed without manual
  intervention.
- Event log confirms `initialize`, `thread/start`, `turn/start`, at least one
  `item/agentMessage/delta`, `thread/tokenUsage/updated`, `turn/completed`.

---

## Nice-to-have

These items improve depth, coverage, or future-proofing. None block initial
production use.

| Feature | Rationale | Dependency or constraint |
|---|---|---|
| OpenCode ACP adapter | ACP (`opencode acp`) is a protocol-compatibility path for environments where the HTTP server is not available or for future ACP-capable runtimes. | Keep secondary to `OpenCodeHttp` until HTTP/SSE path is fully hardened. |
| Reasoning delta event mapping | `RuntimeEvent` declares `:reasoning_delta` but no backend maps to it. Claude Code extended thinking events could populate it. | Low priority until a consumer (Entr'acte dashboard, logging) actually needs it. |
| Hook event normalization | Claude Code can emit `--include-hook-events`. Currently raw passthrough only. Normalizing `PostToolUse`, `PreToolUse`, `Notification`, `Stop` into typed events would let consumers react without parsing raw JSON. | Depends on stable hook event schema from Claude Code CLI. |
| File change approval events | `ApprovalRequest` declares `:file_change` but no backend emits it. Mapping Claude Code file-write permission requests to this type completes approval event coverage. | Requires the approval round-trip must-have first. |
| Formal USL measurements | Record measured `sigma` and `kappa` for fake and real backends at `N = 1, 2, 4, 8, 16` with 100 iterations. Concurrency caps should be based on data, not estimates. | Requires a stable environment and enough turns to suppress noise. |
| Cost estimation for open-source backends | OpenCode reports cost as unsupported with LM Studio. A per-token rate configuration on `RuntimePreset` would let operators populate `cost_usd` from any backend. | Low risk; purely additive to `TokenUsage`. |
| OpenCode token usage verification | OpenCode token usage is degraded (`live_token_usage_needs_black_box_verification`). Black-box verification against the real API would confirm or correct the `step-finish` mapping. | Needs a stable OpenCode instance with a model that reports token counts accurately. |
| Configurable MCP tool bridge | `EntracteTools` hard-codes `linear_graphql` and `gitlab_coverage`. Making the list configurable through `RuntimePreset` means new Entr'acte tools do not require code changes. | Purely additive; existing tools keep working. |
| Structured observability export | Optional OpenTelemetry spans for turn lifecycle events: backend start, first token, turn end, token usage, cost, error. Async sink to keep the hot path clean. | Add only after the normalized event stream is stable enough to export. |
| Packaged distribution | A standalone Sari command would simplify adoption outside this repository. | Wait until the app-server facade, presets, and adapter configuration are stable enough to version. |

---

## Out of Scope

- Replacing Entr'acte's existing Codex app-server reference path.
- Adding a Rust or TypeScript core scheduler without measured evidence that
  Elixir/OTP is the bottleneck.
- Treating real backend smoke results as substitutes for deterministic conformance
  tests.
- Calendar commitments or release dates.

## Validation Expectations

- Documentation-only changes: `make validate`.
- Runtime core changes: deterministic fake-backend tests.
- Backend adapter changes: deterministic adapter coverage plus a real-backend
  black-box proof when credentials and local services are available.
- Concurrency changes: before/after profile evidence with explicit statement of
  whether the bottleneck is contention, coherency, upstream limits, or local
  CPU/memory.
