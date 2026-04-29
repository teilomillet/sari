defmodule Sari.RuntimeError do
  @moduledoc """
  Normalized runtime error envelope used across Sari core and adapters.

  Adapter-specific errors are still preserved in `details` and `source`, but
  callers can reason over the stable `category`, `backend`, `stage`, and
  `retryable` fields.
  """

  @type category :: atom()

  @type t :: %__MODULE__{
          category: category(),
          backend: atom() | nil,
          stage: atom() | nil,
          message: String.t(),
          retryable: boolean(),
          details: map(),
          source: term()
        }

  defstruct category: :unknown,
            backend: nil,
            stage: nil,
            message: "runtime error",
            retryable: false,
            details: %{},
            source: nil

  @spec new(category(), keyword()) :: t()
  def new(category, opts \\ []) when is_atom(category) do
    %__MODULE__{
      category: category,
      backend: Keyword.get(opts, :backend),
      stage: Keyword.get(opts, :stage),
      message: Keyword.get(opts, :message, Atom.to_string(category)),
      retryable: Keyword.get(opts, :retryable, false),
      details: Keyword.get(opts, :details, %{}),
      source: Keyword.get(opts, :source)
    }
  end

  @spec normalize(term(), keyword()) :: t()
  def normalize(reason, opts \\ [])

  def normalize(%__MODULE__{} = error, opts) do
    %__MODULE__{
      error
      | backend: error.backend || Keyword.get(opts, :backend),
        stage: error.stage || Keyword.get(opts, :stage),
        category: error.category
    }
  end

  def normalize({:context_limit_exceeded, details}, opts) when is_map(details) do
    new(
      :context_limit_exceeded,
      opts ++
        [
          message:
            "estimated input tokens exceed configured context limit " <>
              "(#{details.estimated_tokens} > #{details.limit_tokens})",
          retryable: false,
          details: details,
          source: {:context_limit_exceeded, details}
        ]
    )
  end

  def normalize({:opencode_http_error, stage, status, body}, opts) do
    new(
      :http_error,
      opts ++
        [
          stage: stage,
          message: "OpenCode HTTP #{stage} failed with status #{status}",
          retryable: status >= 500,
          details: %{status: status, body_excerpt: body},
          source: {:opencode_http_error, stage, status, body}
        ]
    )
  end

  def normalize({:opencode_transport_error, stage, reason}, opts) do
    new(
      :transport_error,
      opts ++
        [
          stage: stage,
          message: "OpenCode transport #{stage} failed: #{inspect(reason)}",
          retryable: true,
          details: %{reason: inspect(reason)},
          source: {:opencode_transport_error, stage, reason}
        ]
    )
  end

  def normalize({:invalid_opencode_session_response, response}, opts) do
    new(
      :protocol_error,
      opts ++
        [
          stage: :start_session,
          message: "OpenCode returned an invalid session response",
          details: %{response: response},
          source: {:invalid_opencode_session_response, response}
        ]
    )
  end

  def normalize({:invalid_opencode_session_json, reason}, opts) do
    new(
      :protocol_error,
      opts ++
        [
          stage: :start_session,
          message: "OpenCode returned invalid session JSON",
          details: %{reason: inspect(reason)},
          source: {:invalid_opencode_session_json, reason}
        ]
    )
  end

  def normalize({:sse_http_error, status, body}, opts) do
    new(
      :http_error,
      opts ++
        [
          stage: :event_stream,
          message: "OpenCode SSE failed with status #{status}",
          retryable: status >= 500,
          details: %{status: status, body_excerpt: body},
          source: {:sse_http_error, status, body}
        ]
    )
  end

  def normalize({:max_events_exceeded, max_events}, opts) do
    new(
      :stream_limit_exceeded,
      opts ++
        [
          message: "runtime emitted more than #{max_events} events without a terminal event",
          details: %{max_events: max_events},
          source: {:max_events_exceeded, max_events}
        ]
    )
  end

  def normalize(:event_timeout, opts), do: timeout(:event_timeout, "event stream timed out", opts)

  def normalize(:header_timeout, opts),
    do: timeout(:header_timeout, "HTTP header read timed out", opts)

  def normalize(:turn_timeout, opts), do: timeout(:turn_timeout, "turn timed out", opts)

  def normalize({:turn_timeout, timeout_ms, stderr}, opts) do
    timeout(
      :turn_timeout,
      "turn timed out after #{timeout_ms} ms",
      opts ++ [details: stderr_details(stderr, %{timeout_ms: timeout_ms})]
    )
  end

  def normalize({:process_exit, status}, opts) do
    normalize({:process_exit, status, nil}, opts)
  end

  def normalize({:process_exit, status, stderr}, opts) do
    new(
      :process_exit,
      opts ++
        [
          message: "backend process exited with status #{status}",
          retryable: status in [130, 137, 143],
          details: stderr_details(stderr, %{exit_status: status}),
          source: {:process_exit, status, stderr}
        ]
    )
  end

  def normalize({:claude_port_open_failed, message}, opts) do
    new(
      :process_start_failed,
      opts ++
        [
          message: "failed to start Claude Code process: #{message}",
          details: %{reason: message},
          source: {:claude_port_open_failed, message}
        ]
    )
  end

  def normalize(:claude_executable_not_found, opts) do
    new(
      :configuration_error,
      opts ++
        [
          message: "Claude Code executable was not found",
          details: %{executable: "claude"},
          source: :claude_executable_not_found
        ]
    )
  end

  def normalize(:bash_not_found, opts) do
    new(
      :configuration_error,
      opts ++
        [
          message: "bash executable was not found",
          details: %{executable: "bash"},
          source: :bash_not_found
        ]
    )
  end

  def normalize({:invalid_cwd, cwd}, opts) do
    new(
      :invalid_workspace,
      opts ++
        [
          message: "runtime cwd does not exist: #{inspect(cwd)}",
          details: %{cwd: cwd},
          source: {:invalid_cwd, cwd}
        ]
    )
  end

  def normalize({:unsupported, capability}, opts) do
    new(
      :unsupported_capability,
      opts ++
        [
          message: "runtime capability is unsupported: #{capability}",
          details: %{capability: capability},
          source: {:unsupported, capability}
        ]
    )
  end

  def normalize({:missing_capabilities, capabilities}, opts) do
    new(
      :missing_capabilities,
      opts ++
        [
          message: "runtime backend is missing required capabilities",
          details: %{capabilities: capabilities},
          source: {:missing_capabilities, capabilities}
        ]
    )
  end

  def normalize(message, opts) when is_binary(message) do
    new(
      Keyword.get(opts, :category, :unknown),
      opts ++ [message: message, source: message]
    )
  end

  def normalize(reason, opts) do
    new(
      Keyword.get(opts, :category, :unknown),
      opts ++ [message: inspect(reason), details: %{reason: inspect(reason)}, source: reason]
    )
  end

  @spec to_payload(t() | term(), keyword()) :: map()
  def to_payload(error, opts \\ [])

  def to_payload(%__MODULE__{} = error, _opts) do
    %{
      category: error.category,
      message: error.message,
      retryable: error.retryable,
      details: error.details
    }
    |> maybe_put(:backend, error.backend)
    |> maybe_put(:stage, error.stage)
  end

  def to_payload(reason, opts), do: reason |> normalize(opts) |> to_payload()

  @spec code(t() | term(), keyword()) :: String.t()
  def code(error, opts \\ [])

  def code(%__MODULE__{category: category}, _opts), do: Atom.to_string(category)
  def code(reason, opts), do: reason |> normalize(opts) |> code()

  defp timeout(category, message, opts) do
    new(
      :timeout,
      opts ++
        [
          stage: Keyword.get(opts, :stage, category),
          message: message,
          retryable: true,
          source: category
        ]
    )
  end

  defp stderr_details(nil, details), do: details
  defp stderr_details("", details), do: details
  defp stderr_details(stderr, details), do: Map.put(details, :stderr, stderr)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
