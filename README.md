# Sari

Harness app server playground for testing Entr'acte on a real repository.

## Project Direction

Sari is a deliberately small repository for exercising Entr'acte and
Symphony orchestration against real Linear and GitHub workflows. It should stay
minimal and predictable so runner behavior, issue handoff, validation, and PR
publishing can be tested without unrelated application complexity.

## Sari runtime scaffold

This repo now includes the first Elixir scaffold for Sari, a backend-neutral
harness runtime layer. Codex remains the reference path because Entr'acte already
consumes `codex app-server`; Sari is the abstraction layer for making OpenCode,
Claude Code, and future RS backends look like the same runtime to orchestration.
The current scaffold includes a bounded app-server-compatible protocol facade
backed by a deterministic fake backend.

See [docs/sari.md](docs/sari.md).

Use Sari as the merged Entr'acte app-server command with:

```yaml
agent:
  runner: app_server
codex:
  command: /Users/teilomillet/Code/sari/scripts/sari_app_server --backend fake
```

Select OpenCode or Claude Code underneath Sari with `SARI_BACKEND` while keeping
Entr'acte on `app_server`.

Profile the current facade with:

```bash
mix sari.profile --concurrency 1,2,4,8 --iterations 100
```

Probe a local OpenCode server with:

```bash
mix sari.profile --scenario opencode_probe
```

Add `--prompt "hello"` only when you explicitly want to probe OpenCode's
async prompt endpoint. The default probe avoids model/auth-dependent generation
and measures startup, health, SSE connection, and session create/list/delete.

Probe the local Claude Code CLI surface without making a model call:

```bash
mix sari.profile --scenario claude_code_probe
```

Add `--prompt "hello"` only when you explicitly want to run a real Claude Code
turn through Sari's `stream-json` adapter.

Run the real OpenCode HTTP adapter against LM Studio with:

```bash
lms server start --port 1234 --bind 127.0.0.1
lms load google/gemma-4-e4b --context-length 8192 --identifier google/gemma-4-e4b --parallel 1 -y
OPENCODE_CONFIG=$PWD/opencode.lmstudio.json opencode serve --hostname 127.0.0.1 --port 41887
SARI_OPENCODE_BASE_URL=http://127.0.0.1:41887 mix run scripts/sari_opencode_lmstudio_probe.exs
```

Smoke the Entr'acte PR #2 app-server shape through Sari app-server with:

```bash
OPENCODE_CONFIG=$PWD/opencode.lmstudio.json opencode serve --hostname 127.0.0.1 --port 41888
SARI_OPENCODE_BASE_URL=http://127.0.0.1:41888 mix run scripts/sari_app_server_entracte_pr2_smoke.exs
```

The same PR #2 smoke can exercise Claude Code by selecting the Claude backend:

```bash
SARI_BACKEND=claude_code_stream_json \
SARI_ENTRACTE_PROMPT="Reply exactly: sari-claude-ok" \
mix run scripts/sari_app_server_entracte_pr2_smoke.exs
```

## Entr'acte runner

The repo includes a portable runner profile:

```bash
cp .env.example .env
$EDITOR .env
entracte check runner.toml
entracte runner.toml
```

The Linear project is configured through `LINEAR_PROJECT_SLUG` in `.env`.

Use `agent-ready` only when a ticket should be picked up by the Sari runner.
