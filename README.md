# sellerie

Harness app server playground for testing Entr'acte on a real repository.

## Project Direction

sellerie is a deliberately small repository for exercising Entr'acte and
Symphony orchestration against real Linear and GitHub workflows. It should stay
minimal and predictable so runner behavior, issue handoff, validation, and PR
publishing can be tested without unrelated application complexity.

## Entr'acte runner

The repo includes a portable runner profile:

```bash
cp .env.example .env
$EDITOR .env
entracte check runner.toml
entracte runner.toml
```

The Linear project is:

https://linear.app/teilo/project/sellerie-f26dbad5798d/overview

Use `agent-ready` only when a ticket should be picked up by the sellerie runner.
