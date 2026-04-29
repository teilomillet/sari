defmodule Sari do
  @moduledoc """
  Sari is a backend-neutral harness runtime layer.

  The core owns stable runtime primitives. Backend-specific integrations such as
  Codex app-server, OpenCode, Claude Code, ACP, HTTP/SSE, or JSONL streams belong
  behind `Sari.RuntimeBackend` implementations.
  """
end
