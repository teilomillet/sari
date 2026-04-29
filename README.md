# sellerie

Harness app server playground for testing Entr'acte on a real repository.

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
