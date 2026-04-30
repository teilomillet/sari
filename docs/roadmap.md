# Sari Roadmap

This roadmap prioritizes the next Sari features from the evidence already in
this repository: `README.md`, `docs/sari.md`, `WORKFLOW.md`, the runtime
capability declarations, and the Entr'acte-compatible protocol tests. It is a
priority map, not a dated release plan.

## Basis

- Sari's primary job is to make OpenCode, Claude Code, and future RS backends
  consumable through the same Entr'acte operational path.
- Entr'acte currently consumes an app-server process through the `codex.command`
  compatibility slot, so preserving that facade is the near-term integration
  path.
- Backend-specific behavior belongs behind runtime adapters; the Elixir core
  owns lifecycle, supervision, event normalization, approvals, observability,
  cancellation, retries, and backpressure.
- Unsupported and degraded capabilities must be explicit. Silent omission is a
  product risk because orchestration must fail closed.

## Must-have Features

| Feature | Why it is must-have | Evidence | Done when |
| --- | --- | --- | --- |
| Entr'acte-compatible app-server facade | This is the integration path that lets Entr'acte run Sari without knowing the backend underneath. | `docs/sari.md` documents the merged app-server path, and `Sari.AppServer.Protocol` implements the bounded JSON-RPC surface. | `initialize`, `thread/start`, `turn/start`, streaming notifications, token usage, tool/approval events, and terminal turn events stay covered by contract fixtures. |
| Backend-neutral runtime core | Sari should not leak Codex, OpenCode, or Claude-specific shapes into the common abstraction. | `WORKFLOW.md` defines runtime primitives such as `RuntimeBackend`, `Session`, `Turn`, `RuntimeEvent`, `ApprovalRequest`, and `TokenUsage`. | Core APIs and docs use backend-neutral vocabulary, with backend-specific logic contained in adapters. |
| Deterministic conformance and fake backend coverage | The runtime needs a local proof that does not depend on external models, auth, ports, or network state. | `Sari.Backend.Fake`, `Sari.RuntimeConformance`, and app-server JSONL fixtures already provide this path. | Every registered backend declares the full capability map and deterministic tests verify normalized event streams with exactly one terminal event. |
| Capability matrix and preset registry | Operators need to know which backend supports streaming, approvals, tools, cancellation, cost, resume, workspace mode, and context guards before choosing a runtime. | `Sari.CapabilityMatrix` and `Sari.RuntimePreset` already expose the consumer-facing matrix and workflow snippets. | `mix sari.capabilities` and `mix sari.presets` remain accurate and are updated with every backend capability change. |
| OpenCode HTTP adapter hardening | OpenCode's HTTP/SSE server is the preferred surface for sessions, permissions, tools, files, events, and observability. | `WORKFLOW.md` says to prefer `OpenCodeHttp` when Sari needs observability, session control, permissions, and events. | Health, SSE, session lifecycle, prompt submission, cancellation, timeout, token/cost, and unsupported permission semantics are mapped or explicitly marked degraded. |
| Claude Code stream-json adapter hardening | Claude Code is a key backend, but Sari must own subprocess lifecycle, stream parsing, timeouts, event normalization, and cleanup. | `WORKFLOW.md` and `docs/sari.md` describe one subprocess per turn until explicit stop-session semantics exist. | Claude turns produce normalized start/delta/tool/token/terminal events, clean up temporary MCP/config state, and surface process failures through `Sari.RuntimeError`. |
| Dynamic tool and approval routing | Entr'acte injects tools such as `linear_graphql` and `gitlab_coverage`; Sari must keep that tool path available across supported backends. | `Sari.Mcp.EntracteTools` exposes the current Entr'acte tool surface to Claude Code through MCP. | Supported dynamic tools can be called from compatible backends, approval requests are explicit, and unsupported tools fail closed. |
| Prompt budget and failure semantics | Runtime failures need predictable, typed behavior rather than partial or malformed protocol streams. | `docs/sari.md` documents prompt budget guards, turn timeouts, stderr cleanup, and normalized error envelopes. | Oversized prompts, unknown threads, malformed messages, timeouts, backend failures, and missing terminal events produce deterministic errors. |
| Profiling and concurrency evidence | Sari runner defaults should be based on measured contention and coherency costs, not optimism. | `WORKFLOW.md` mandates the Universal Scaling Law model, and `Sari.Profile` records latency, throughput, reductions, memory, mailbox, and error metrics. | Core and backend sweeps can compare fake, OpenCode, and Claude paths without conflating their bottlenecks. |
| Repository validation path | The roadmap is only useful if the documented contract stays green as work lands. | `Makefile` defines `make validate` as `git diff --check`, formatter checks, and tests. | Every roadmap-affecting PR documents and runs the relevant targeted proof plus `make validate`. |

## Nice-to-have Features

| Feature | Why it is nice-to-have | Dependency or uncertainty |
| --- | --- | --- |
| Resident Claude Code session mode | Reusing a stream-json process could reduce startup overhead and preserve richer session continuity. | Wait until Sari has an explicit backend `stop_session` contract so resident processes can be cleaned up safely. |
| OpenCode ACP adapter | ACP would provide a protocol-compatibility path that may generalize beyond OpenCode. | Keep it secondary to the HTTP adapter until the long-running HTTP/SSE path is hardened. |
| Neutral Entr'acte configuration keys | Moving from `codex.command` to `runtime.command` or `sari.command` would make the orchestration contract clearer. | Do this after the compatibility facade is proven, and keep backward compatibility for existing workflows. |
| More backend adapters | Additional RS backends increase the value of the Sari abstraction. | Add only after the core conformance suite and two non-Codex backends prove the adapter boundary. |
| Automated real-backend smoke matrix | CI or scheduled checks against real OpenCode and Claude surfaces would catch upstream drift faster. | Real backend checks depend on local servers, credentials, model availability, and cost controls, so they should stay opt-in or gated. |
| Richer observability exports | Structured traces, dashboard views, and cost summaries would make production operations easier. | First keep the normalized event stream and profile data stable enough to export. |
| Packaged distribution | A packaged Sari command would simplify adoption outside this repository. | Wait until the app-server facade, presets, and adapter configuration are stable. |
| Quantitative USL fitting | Fitting `sigma` and `kappa` from profile output would sharpen concurrency defaults. | Requires enough stable measurements across fake, OpenCode, and Claude paths to avoid false precision. |

## Out Of Scope For This Roadmap

- Replacing Entr'acte's existing Codex app-server reference path.
- Adding a Rust or TypeScript core scheduler without measured evidence that
  Elixir/OTP is the bottleneck.
- Treating real backend smoke results as interchangeable with deterministic
  conformance tests.
- Calendar commitments or release dates; the issue only asks for feature
  priority.

## Validation Expectations

- Documentation-only roadmap changes should run `make validate`.
- Runtime core changes should include deterministic fake-backend tests.
- Backend adapter changes should include deterministic adapter coverage plus a
  black-box real-backend proof when credentials and local services are
  available.
- Concurrency changes should record before/after profile evidence and state
  whether the suspected bottleneck is contention, coherency, upstream limits, or
  local CPU/memory.
