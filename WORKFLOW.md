---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: $LINEAR_PROJECT_SLUG
  assignee: $LINEAR_ASSIGNEE
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
dispatch:
  require_ready_label: true
  ready_label: agent-ready
  paused_label: agent-paused
polling:
  interval_ms: 5000
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    : "${SOURCE_REPO_URL:?Set SOURCE_REPO_URL to the repository URL this runner should clone}"
    git clone --depth 1 "$SOURCE_REPO_URL" .
    if command -v mise >/dev/null 2>&1; then
      mise trust || true
      mise install || true
    fi
    if [ -f package.json ]; then
      if command -v pnpm >/dev/null 2>&1; then
        pnpm install
      elif command -v npm >/dev/null 2>&1; then
        npm install
      fi
    fi
    if [ -f mix.exs ]; then
      if command -v mise >/dev/null 2>&1; then
        mise exec -- mix deps.get
      else
        mix deps.get
      fi
    fi
  before_remove: |
    true
agent:
  max_concurrent_agents: 2
  max_turns: 20
codex:
  command: "${CODEX_BIN:-codex} --config shell_environment_policy.inherit=all --config 'model=\"gpt-5.5\"' --config model_reasoning_effort=xhigh app-server"
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
---

You are working on a tracked ticket `{{ issue.identifier }}`

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the ticket is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Do not end the turn while the issue remains in an active state unless you are blocked by missing required permissions/secrets.
  {% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
2. Only stop early for a true blocker (missing required auth/permissions/secrets). If blocked, record it in the workpad and move the issue according to workflow.
3. Final message must report completed actions and blockers only. Do not include "next steps for user".

Work only in the provided repository copy. Do not touch any other path.

## Prerequisite: Linear MCP or `linear_graphql` tool is available

The agent should be able to talk to Linear, either via a configured Linear MCP server or injected `linear_graphql` tool. If none are present, stop and ask the user to configure Linear.

## Default posture

- Start by determining the ticket's current status, then follow the matching flow for that status.
- Start every task by opening the tracking workpad comment and bringing it up to date before doing new implementation work.
- Spend extra effort up front on planning and verification design before implementation.
- Reproduce first: always confirm the current behavior/issue signal before changing code so the fix target is explicit.
- Treat every material architectural claim as an epistemic claim: record the observed evidence, inference, decision, and remaining uncertainty before implementation.
- Treat the issue plus workpad as an executable task contract: desired change,
  current evidence, scope boundaries, acceptance criteria, validation, and
  unknowns must be explicit before coding.
- For Sari/harness work, design from the runtime boundary inward. Do not let Codex, OpenCode, Claude Code, ACP, or any other RS-specific shape leak into the core abstraction unless the workpad justifies why the core primitive must exist.
- Default Sari core implementation language is Elixir/OTP. Use Rust, TypeScript, or another runtime only behind an adapter/sidecar boundary when measured constraints or upstream SDK realities justify it in the workpad.
- Keep branch history linear. Sync with `origin/main` by rebase or
  fast-forward only; do not introduce merge commits while updating a work
  branch.
- Keep ticket metadata current (state, checklist, acceptance criteria, links).
- Treat a single persistent Linear comment as the source of truth for progress.
- Use that single workpad comment for all progress and handoff notes; do not post separate "done"/summary comments.
- Treat any ticket-authored `Validation`, `Test Plan`, or `Testing` section as non-negotiable acceptance input: mirror it in the workpad and execute it before considering the work complete.
- When meaningful out-of-scope improvements are discovered during execution,
  file a separate Linear issue instead of expanding scope. The follow-up issue
  must include a clear title, description, and acceptance criteria, be placed in
  `Backlog`, be assigned to the same project as the current issue, link the
  current issue as `related`, and use `blockedBy` when the follow-up depends on
  the current issue.
- Move status only when the matching quality bar is met.
- Operate autonomously end-to-end unless blocked by missing requirements, secrets, or permissions.
- Use the blocked-access escape hatch only for true external blockers (missing required tools/auth) after exhausting documented fallbacks.

## Sari architecture contract

Apply this section to every ticket that touches the harness abstraction, runtime adapters, monitoring, agent execution, or Codex/OpenCode/Claude Code compatibility.

- Sari is the umbrella runtime. Codex app-server is one adapter and compatibility target, not the architecture.
- Entr'acte/Symphony is the primary consumer. Codex is already fit because Entr'acte already consumes `codex app-server`; Sari succeeds when OpenCode, Claude Code, and future RS backends can be consumed through the same Entr'acte operational path.
- "Support an RS like codex-app-server" means an external orchestrator can start/resume a session, send a turn, receive streamed normalized events, answer approvals/tool requests, inspect state, cancel work, and cleanly terminate the runtime without knowing which backend is underneath.
- The Elixir/OTP core owns supervision, session and turn lifecycle, adapter process ownership, event normalization, approval routing, observability, retries, cancellation, and backpressure.
- Backend-specific code belongs behind a runtime adapter boundary. New code should prefer names such as `runtime`, `backend`, `session`, `turn`, and `event`; use `codex` only for Codex-specific adapter code or compatibility tests.
- Preserve a Codex app-server-compatible facade where existing orchestration needs it, but keep Sari's internal vocabulary backend-neutral.
- Do not spend implementation effort "making Codex fit" except to extract conformance tests, preserve compatibility, or keep the existing Entr'acte path green.
- Normalize all supported RS backends into stable Sari primitives:
  - `RuntimeBackend`
  - `RuntimeCapabilities`
  - `Session`
  - `Turn`
  - `RuntimeEvent`
  - `ToolCall`
  - `CommandExecution`
  - `FileChange`
  - `ApprovalRequest`
  - `TokenUsage`
- A runtime adapter must explicitly declare unsupported capabilities instead of silently degrading behavior.
- A runtime adapter must make process, transport, and stream ownership explicit: stdio JSON-RPC, HTTP/SSE, JSONL stream, ACP, MCP, or sidecar process.
- A Sari core change must include a fake/deterministic backend test unless the ticket is documentation-only.
- A backend adapter change must include either:
  - a black-box proof against the real backend command/API, or
  - a documented reason that the real backend could not run plus deterministic adapter tests that exercise the same protocol surface.
- Do not introduce a Rust or TypeScript core scheduler. Rust is reserved for hardened protocol/process sidecars after evidence shows Elixir is the bottleneck. TypeScript is reserved for SDK-facing adapters where the upstream integration is materially safer through the upstream SDK.
- When exploring a new RS backend, record these findings before design:
  - launch/control surface,
  - session/resume support,
  - streaming/event support,
  - tool and approval model,
  - filesystem/command execution model,
  - cancellation semantics,
  - observability/token/cost data,
  - security/sandbox controls,
  - adapter gaps and risk.

## Entr'acte consumption contract

Use the Entr'acte/Symphony Codex app-server client as the concrete reference consumer. In the current Elixir implementation, Entr'acte launches the configured command in the issue workspace, speaks JSON-RPC over line-buffered stdio, and handles a bounded app-server subset.

Required compatibility surface for a Sari facade consumed by Entr'acte:

- Launch from the workflow command slot currently named `codex.command`, or from a future neutral runtime command slot that preserves the same operational behavior.
- Start in the issue workspace selected by Entr'acte.
- Accept `initialize` and the follow-up `initialized` notification.
- Accept `thread/start` with working directory, approval policy, sandbox or permissions policy, and dynamic tool specifications.
- Return a thread identifier that Entr'acte can reuse across continuation turns.
- Accept `turn/start` with thread ID, text input, working directory, title, approval policy, and sandbox policy.
- Stream JSON messages while the turn runs.
- Produce a clear terminal turn event equivalent to `turn/completed`, `turn/failed`, or `turn/cancelled`.
- Surface command/file/tool approvals as explicit requests that Entr'acte can approve, reject, auto-approve, or fail closed.
- Support dynamic tool calls so Entr'acte can inject tools such as `linear_graphql`.
- Preserve enough metadata for the dashboard and logs: runtime name, adapter name, backend process or server identity, thread ID, turn ID, last event, last message, timestamps, token/cost data when available, and worker host when remote.
- Fail closed on malformed protocol messages, missing terminal events, unhandled approval requests, unsupported tools, and timeout.

Implementation guidance:

- Treat the existing Codex app-server client behavior in `Code/entracte` as the acceptance harness for Sari's compatibility facade.
- Prefer first implementing Sari as a command that Entr'acte can run in place of `codex app-server`; this proves OpenCode/Claude Code compatibility without requiring Entr'acte orchestration changes.
- Once the facade is proven, consider renaming configuration from `codex.*` to neutral `runtime.*`/`sari.*` in Entr'acte as a separate migration. Keep backward compatibility while doing so.
- Do not require Entr'acte to know whether the backend is Codex, OpenCode, Claude Code, ACP, HTTP/SSE, or JSONL. That decision belongs in Sari configuration and adapter capabilities.
- Entr'acte-facing compatibility tests should use a fake Sari backend first, then black-box tests for OpenCode and Claude Code when credentials and tools are available.

## Target RS adapter context

This context is intentionally in the workflow so unattended agents do not rediscover the same architecture facts. Verify upstream docs before relying on details that may have changed.

### Codex app-server

- Role in Sari: already-supported reference path through Entr'acte, compatibility fixture, and conformance baseline.
- Shape: JSON-RPC over stdio, Unix socket, or WebSocket depending on launch options.
- Sari responsibility: preserve compatibility where useful, but extract only stable cross-runtime primitives into core.
- Do not copy Codex-only protocol details into `RuntimeBackend` unless OpenCode and Claude Code can map to them or the workpad justifies a deliberate optional capability.
- Codex adapter work should usually be limited to conformance coverage, regression fixes, or proving that Sari did not break the existing Entr'acte path.

### OpenCode

Observed integration surfaces:

- `opencode serve` starts a headless HTTP server for API access.
- The server exposes OpenAPI documentation at `/doc`.
- The server exposes server-sent events at `/global/event`.
- The server exposes sessions, messages, async prompts, permissions, files, tools, MCP status, agents, logging, TUI control, auth, and VCS/path APIs.
- `opencode run --format json` provides raw JSON events for non-interactive scripting.
- `opencode run --attach http://localhost:<port>` can reuse a running server and avoid repeated cold starts.
- `opencode acp` starts an Agent Client Protocol subprocess over stdio/JSON-RPC/nd-JSON.

Adapter guidance:

- Prefer an `OpenCodeHttp` adapter first when Sari needs observability, session control, permissions, and events.
- Keep an `OpenCodeAcp` adapter as a protocol-compatibility path for future ACP-capable runtimes.
- Treat `opencode run` as useful for smoke tests and compatibility probes, not as the primary long-running Sari integration when the HTTP server is available.
- Track cold-start and hot-attach latency separately because they create different scaling profiles.
- Keep prompt-path probes opt-in. Default profiling should measure startup, health, SSE, and session lifecycle without requiring provider credentials or spending model tokens.
- Record which OpenCode permission responses are one-shot vs remembered and map that explicitly into Sari approval events.

Official references:

- https://opencode.ai/docs/cli/
- https://dev.opencode.ai/docs/server/
- https://opencode.ai/docs/acp/

### Claude Code

Observed integration surfaces:

- `claude -p` runs non-interactively and exits.
- `--output-format stream-json` emits machine-readable streaming output.
- `--input-format stream-json` accepts streamed user turns over stdin.
- `--include-hook-events` includes lifecycle hook events in the stream.
- `--include-partial-messages` includes partial response chunks.
- `--resume`, `--continue`, `--fork-session`, and `--session-id` support session continuity.
- `--permission-prompt-tool` lets non-interactive permission prompts route through an MCP tool.
- Hooks expose session, turn, tool, permission, compaction, file, cwd, notification, and other lifecycle events to command or HTTP handlers.

Adapter guidance:

- Prefer a `ClaudeCodeStreamJson` adapter that owns the subprocess, stdin/stdout JSONL parsing, cancellation, and final-result detection.
- In the current Sari runtime contract, prefer one Claude Code subprocess per turn because the backend behaviour has no explicit `stop_session` callback. This avoids leaking resident ports. Move to a resident stream-json process only after session shutdown is part of the contract.
- Use hooks and `--permission-prompt-tool` to recover event and approval fidelity that is native in Codex app-server.
- Treat Claude Code as a powerful stream/process backend, not as a native app-server. Sari must own session bookkeeping, adapter state, timeout policy, and event normalization.
- Capture the exact command, flags, settings source, MCP config, allowed/disallowed tools, and permission mode in adapter metadata.
- Record unsupported semantics explicitly. For example, if a Codex app-server event has no Claude Code equivalent, emit a typed unsupported capability or degraded event rather than silently omitting it.

Official references:

- https://code.claude.com/docs/en/cli-reference
- https://code.claude.com/docs/en/agent-sdk/streaming-output
- https://code.claude.com/docs/en/hooks

## USL scaling model for Sari

Use the Universal Scaling Law as the default mental model for Sari concurrency work:

```text
C(N) = N / (1 + sigma * (N - 1) + kappa * N * (N - 1))
Nmax = sqrt((1 - sigma) / kappa)
```

Definitions for Sari:

- `N`: concurrent sessions, workers, backend processes, or load generators.
- `C(N)`: completed useful turns per unit time, normalized to one worker.
- `sigma`: contention cost from shared resources such as global queues, DB writes, log sinks, rate limits, shared approval brokers, or process table pressure.
- `kappa`: coherency cost from cross-session coordination such as global state synchronization, broadcast fanout, shared mutable caches, lock-step supervision, or every adapter needing to observe every other adapter.

Operational rules:

- Do not assume that increasing `agent.max_concurrent_agents`, workers, ports, or adapter processes increases throughput.
- Treat retrograde throughput as a diagnostic signal: if throughput drops as `N` grows, investigate coherency first, then contention.
- Design Sari so most state is session-local and adapter-local. Core should coordinate by messages and immutable event snapshots, not shared mutable state.
- Prefer sharded queues, per-session supervisors, bounded mailboxes, bounded event buffers, async observability ingestion, and explicit backpressure over global locks or synchronous broadcast paths.
- Keep approval routing and observability out of the hot path where possible. If they must be in the path, measure their latency contribution separately.
- For every concurrency or throughput ticket, collect steady-state measurements at several load levels before and after the change. At minimum record `N`, throughput, p50/p95 turn duration, queue wait, adapter startup time, event lag, mailbox depth or queue depth, error/retry rate, token/cost rate where available, CPU, memory, open file descriptors, and backend/API rate-limit signals.
- Fit or reason about `sigma` and `kappa` qualitatively even when there is not enough data for a formal regression. The workpad must say whether the suspected bottleneck is contention, coherency, upstream rate limits, or local CPU/memory.
- Pick default concurrency caps below the measured peak, not at the optimistic maximum.
- If there are not enough stable data points, state that explicitly and keep the cap conservative.

Reference:

- https://teilo.xyz/collections/universal-scaling-law/

## Related skills

- `linear`: interact with Linear.
- `commit`: produce clean, logical commits during implementation.
- `push`: keep remote branch current and publish updates.
- `pull`: rebase/fast-forward the branch onto latest `origin/main`.
- `land`: when ticket reaches `Merging`, explicitly open and follow `.codex/skills/land/SKILL.md`, which includes the `land` loop.

## Status map

- `Backlog` -> out of scope for this workflow; do not modify.
- `Todo` -> queued; immediately transition to `In Progress` before active work.
  - Special case: if a PR is already attached, treat as feedback/rework loop (run full PR feedback sweep, address or explicitly push back, revalidate, return to `Human Review`).
- `In Progress` -> implementation actively underway.
- `Human Review` -> PR is attached and validated; waiting on human approval.
- `Merging` -> approved by human; execute the `land` skill flow (do not call `gh pr merge` directly).
- `Rework` -> reviewer requested changes; planning + implementation required.
- `Done` -> terminal state; no further action required.

## Step 0: Determine current ticket state and route

1. Fetch the issue by explicit ticket ID.
2. Read the current state.
3. Route to the matching flow:
   - `Backlog` -> do not modify issue content/state; stop and wait for human to move it to `Todo`.
   - `Todo` -> immediately move to `In Progress`, then ensure bootstrap workpad comment exists (create if missing), then start execution flow.
     - If PR is already attached, start by reviewing all open PR comments and deciding required changes vs explicit pushback responses.
   - `In Progress` -> continue execution flow from current scratchpad comment.
   - `Human Review` -> wait and poll for decision/review updates.
   - `Merging` -> on entry, open and follow `.codex/skills/land/SKILL.md`; do not call `gh pr merge` directly.
   - `Rework` -> run rework flow.
   - `Done` -> do nothing and shut down.
4. Check whether a PR already exists for the current branch and whether it is closed.
   - If a branch PR exists and is `CLOSED` or `MERGED`, treat prior branch work as non-reusable for this run.
   - Create a fresh branch from `origin/main` and restart execution flow as a new attempt.
5. For `Todo` tickets, do startup sequencing in this exact order:
   - `update_issue(..., state: "In Progress")`
   - find/create `## Codex Workpad` bootstrap comment
   - only then begin analysis/planning/implementation work.
6. Add a short comment if state and issue content are inconsistent, then proceed with the safest flow.

## Step 1: Start/continue execution (Todo or In Progress)

1.  Find or create a single persistent scratchpad comment for the issue:
    - Search existing comments for a marker header: `## Codex Workpad`.
    - Ignore resolved comments while searching; only active/unresolved comments are eligible to be reused as the live workpad.
    - If found, reuse that comment; do not create a new workpad comment.
    - If not found, create one workpad comment and use it for all updates.
    - Persist the workpad comment ID and only write progress updates to that ID.
2.  If arriving from `Todo`, do not delay on additional status transitions: the issue should already be `In Progress` before this step begins.
3.  Immediately reconcile the workpad before new edits:
    - Check off items that are already done.
    - Expand/fix the plan so it is comprehensive for current scope.
    - Ensure `Acceptance Criteria` and `Validation` are current and still make sense for the task.
    - Ensure the `Task Contract` section is specific enough to execute without guessing.
4.  Start work by writing/updating the `Task Contract` and a hierarchical plan in the workpad comment.
5.  Ensure the workpad includes a compact environment stamp at the top as a code fence line:
    - Format: `<host>:<abs-workdir>@<short-sha>`
    - Example: `devbox-01:/home/dev-user/code/sari-workspaces/SARI-32@7bdde33bc`
    - Do not include metadata already inferable from Linear issue fields (`issue ID`, `status`, `branch`, `PR link`).
6.  Add explicit acceptance criteria and TODOs in checklist form in the same comment.
    - Fill `Task Contract` with desired outcome, current evidence/signal, in-scope work, out-of-scope work, validation contract, and unknowns.
    - For Sari/harness work, include the runtime boundary, adapter surface, compatibility target, and non-goals explicitly.
    - If the issue is broad, ambiguous, or mixes unrelated outcomes, narrow it into an executable task contract before implementation.
    - If the contract cannot be narrowed without human product intent, move the issue to `Human Review` with a blocker brief instead of guessing.
    - If changes are user-facing, include a UI walkthrough acceptance criterion that describes the end-to-end user path to validate.
    - If changes touch app files or app behavior, add explicit app-specific flow checks to `Acceptance Criteria` in the workpad (for example: launch path, changed interaction path, and expected result path).
    - If the ticket description/comment context includes `Validation`, `Test Plan`, or `Testing` sections, copy those requirements into the workpad `Acceptance Criteria` and `Validation` sections as required checkboxes (no optional downgrade).
7.  Run a principal-style self-review of the plan and refine it in the comment.
    - For Sari/harness work, the self-review must challenge whether the change belongs in core, adapter, config, protocol facade, or observability.
8.  Before implementing, capture a concrete reproduction signal and record it in the workpad `Notes` section (command/output, screenshot, or deterministic UI behavior).
9.  Run the `pull` skill to rebase/fast-forward onto latest `origin/main` before any code edits, then record the sync result in the workpad `Notes`.
    - Include a `sync evidence` note with:
      - fetched source refs,
      - method (`rebase` or `ff-only`),
      - result (`clean` or `conflicts resolved`),
      - resulting `HEAD` short SHA.
10. Compact context and proceed to execution.

## PR feedback sweep protocol (required)

When a ticket has an attached PR, run this protocol before moving to `Human Review`:

1. Identify the PR number from issue links/attachments.
2. Gather feedback from all channels:
   - Top-level PR comments (`gh pr view --comments`).
   - Inline review comments (`gh api repos/<owner>/<repo>/pulls/<pr>/comments`).
   - Review summaries/states (`gh pr view --json reviews`).
3. Treat every actionable reviewer comment (human or bot), including inline review comments, as blocking until one of these is true:
   - code/test/docs updated to address it, or
   - explicit, justified pushback reply is posted on that thread.
4. Update the workpad plan/checklist to include each feedback item and its resolution status.
5. Re-run validation after feedback-driven changes and push updates.
6. Repeat this sweep until there are no outstanding actionable comments.

## Blocked-access escape hatch (required behavior)

Use this only when completion is blocked by missing required tools or missing auth/permissions that cannot be resolved in-session.

- GitHub is **not** a valid blocker by default. Always try fallback strategies first (alternate remote/auth mode, then continue publish/review flow).
- Do not move to `Human Review` for GitHub access/auth until all fallback strategies have been attempted and documented in the workpad.
- If a non-GitHub required tool is missing, or required non-GitHub auth is unavailable, move the ticket to `Human Review` with a short blocker brief in the workpad that includes:
  - what is missing,
  - why it blocks required acceptance/validation,
  - exact human action needed to unblock.
- Keep the brief concise and action-oriented; do not add extra top-level comments outside the workpad.

## Step 2: Execution phase (Todo -> In Progress -> Human Review)

1.  Determine current repo state (`branch`, `git status`, `HEAD`) and verify the kickoff rebase/fast-forward sync result is already recorded in the workpad before implementation continues.
2.  If current issue state is `Todo`, move it to `In Progress`; otherwise leave the current state unchanged.
3.  Load the existing workpad comment and treat it as the active execution checklist.
    - Edit it liberally whenever reality changes (scope, risks, validation approach, discovered tasks).
4.  Implement against the hierarchical TODOs and keep the comment current:
    - Check off completed items.
    - Add newly discovered items in the appropriate section.
    - Keep parent/child structure intact as scope evolves.
    - Update the workpad immediately after each meaningful milestone (for example: reproduction complete, code change landed, validation run, review feedback addressed).
    - Never leave completed work unchecked in the plan.
    - For tickets that started as `Todo` with an attached PR, run the full PR feedback sweep protocol immediately after kickoff and before new feature work.
5.  Run validation/tests required for the scope.
    - Mandatory gate: execute all ticket-provided `Validation`/`Test Plan`/ `Testing` requirements when present; treat unmet items as incomplete work.
    - Prefer a targeted proof that directly demonstrates the behavior you changed.
    - For Sari/harness work, validate the normalized runtime contract with deterministic tests before relying on a real RS backend smoke test.
    - You may make temporary local proof edits to validate assumptions (for example: tweak a local build input for `make`, or hardcode a UI account / response path) when this increases confidence.
    - Revert every temporary proof edit before commit/push.
    - Document these temporary proof steps and outcomes in the workpad `Validation`/`Notes` sections so reviewers can follow the evidence.
    - If app-touching, run project-specific runtime/manual validation documented in the issue or repo and capture evidence when practical.
6.  Re-check all acceptance criteria and close any gaps.
7.  Before every `git push` attempt, run the required validation for your scope and confirm it passes; if it fails, address issues and rerun until green, then commit and push changes.
8.  Attach PR URL to the issue (prefer attachment; use the workpad comment only if attachment is unavailable).
    - Ensure the GitHub PR has label `symphony` (add it if missing).
9.  Rebase or fast-forward onto latest `origin/main`, resolve conflicts, and rerun checks. Do not merge `origin/main` into the work branch.
10. Update the workpad comment with final checklist status and validation notes.
    - Mark completed plan/acceptance/validation checklist items as checked.
    - Add final handoff notes (commit + validation summary) in the same workpad comment.
    - Do not include PR URL in the workpad comment; keep PR linkage on the issue via attachment/link fields.
    - Add a short `### Confusions` section at the bottom when any part of task execution was unclear/confusing, with concise bullets.
    - Do not post any additional completion summary comment.
11. Before moving to `Human Review`, poll PR feedback and checks:
    - Read the PR `Manual QA Plan` comment (when present) and use it to sharpen UI/runtime test coverage for the current change.
    - Run the full PR feedback sweep protocol.
    - Confirm PR checks are passing (green) after the latest changes.
    - Confirm every required ticket-provided validation/test-plan item is explicitly marked complete in the workpad.
    - Repeat this check-address-verify loop until no outstanding comments remain and checks are fully passing.
    - Re-open and refresh the workpad before state transition so `Plan`, `Acceptance Criteria`, and `Validation` exactly match completed work.
12. Only then move issue to `Human Review`.
    - Exception: if blocked by missing required non-GitHub tools/auth per the blocked-access escape hatch, move to `Human Review` with the blocker brief and explicit unblock actions.
13. For `Todo` tickets that already had a PR attached at kickoff:
    - Ensure all existing PR feedback was reviewed and resolved, including inline review comments (code changes or explicit, justified pushback response).
    - Ensure branch was pushed with any required updates.
    - Then move to `Human Review`.

## Step 3: Human Review and merge handling

1. When the issue is in `Human Review`, do not code or change ticket content.
2. Poll for updates as needed, including GitHub PR review comments from humans and bots.
3. If review feedback requires changes, move the issue to `Rework` and follow the rework flow.
4. If approved, human moves the issue to `Merging`.
5. When the issue is in `Merging`, open and follow `.codex/skills/land/SKILL.md`, then run the `land` skill in a loop until the PR is merged. Do not call `gh pr merge` directly.
6. After merge is complete, move the issue to `Done`.

## Step 4: Rework handling

1. Treat `Rework` as a full approach reset, not incremental patching.
2. Re-read the full issue body and all human comments; explicitly identify what will be done differently this attempt.
3. Close the existing PR tied to the issue.
4. Remove the existing `## Codex Workpad` comment from the issue.
5. Create a fresh branch from `origin/main`.
6. Start over from the normal kickoff flow:
   - If current issue state is `Todo`, move it to `In Progress`; otherwise keep the current state.
   - Create a new bootstrap `## Codex Workpad` comment.
   - Build a fresh plan/checklist and execute end-to-end.

## Completion bar before Human Review

- Step 1/2 checklist is fully complete and accurately reflected in the single workpad comment.
- Acceptance criteria and required ticket-provided validation items are complete.
- Validation/tests are green for the latest commit.
- PR feedback sweep is complete and no actionable comments remain.
- PR checks are green, branch is pushed, and PR is linked on the issue.
- Branch is rebased or fast-forwarded onto latest `origin/main` with no merge commits introduced by the agent.
- Required PR metadata is present (`symphony` label).
- If app-touching, runtime validation/media requirements from `App runtime validation (required)` are complete.
- If Sari/harness-touching, the workpad contains explicit evidence for the runtime boundary, adapter capabilities, unsupported capability behavior, and validation performed against fake and/or real backends.

## Guardrails

- If the branch PR is already closed/merged, do not reuse that branch or prior implementation state for continuation.
- For closed/merged branch PRs, create a new branch from `origin/main` and restart from reproduction/planning as if starting fresh.
- If issue state is `Backlog`, do not modify it; wait for human to move to `Todo`.
- Do not edit the issue body/description for planning or progress tracking.
- Use exactly one persistent workpad comment (`## Codex Workpad`) per issue.
- If comment editing is unavailable in-session, use the update script. Only report blocked if both MCP editing and script-based editing are unavailable.
- Temporary proof edits are allowed only for local verification and must be reverted before commit.
- If out-of-scope improvements are found, create a separate Backlog issue rather
  than expanding current scope, and include a clear
  title/description/acceptance criteria, same-project assignment, a `related`
  link to the current issue, and `blockedBy` when the follow-up depends on the
  current issue.
- Do not merge `origin/main` into work branches. Use rebase or fast-forward
  sync, and use `--force-with-lease` only after a local history rewrite.
- Do not move to `Human Review` unless the `Completion bar before Human Review` is satisfied.
- In `Human Review`, do not make changes; wait and poll.
- If state is terminal (`Done`), do nothing and shut down.
- Keep issue text concise, specific, and reviewer-oriented.
- If blocked and no workpad exists yet, add one blocker comment describing blocker, impact, and next unblock action.
- Keep the `## Codex Workpad` marker until the runner and existing automation are migrated to a neutral marker. Sari work should still use this marker for compatibility.

## Workpad template

Use this exact structure for the persistent workpad comment and keep it updated in place throughout execution:

````md
## Codex Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Task Contract

- Desired outcome:
- Current evidence/signal:
- Runtime boundary:
- Compatibility target:
- In scope:
- Out of scope:
- Validation contract:
- Unknowns:

### Evidence and Decisions

- Observed:
- Inferred:
- Decision:
- Uncertainty:

### Runtime Adapter Contract

- Backend/runtime:
- Transport/process shape:
- Launch/control surface:
- Session/resume semantics:
- Event stream semantics:
- Approval/tool semantics:
- Filesystem/command semantics:
- Unsupported/degraded capabilities:
- Security/sandbox notes:

### USL / Scaling Notes

- Load unit `N`:
- Expected contention (`sigma`) sources:
- Expected coherency (`kappa`) sources:
- Conservative concurrency cap:
- Measurements planned or collected:

### Plan

- [ ] 1\. Parent task
  - [ ] 1.1 Child task
  - [ ] 1.2 Child task
- [ ] 2\. Parent task

### Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2

### Validation

- [ ] targeted tests: `<command>`

### Notes

- <short progress note with timestamp>

### Confusions

- <only include when something was confusing during execution>
````
