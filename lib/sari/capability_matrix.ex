defmodule Sari.CapabilityMatrix do
  @moduledoc """
  Machine-readable capability matrix for Sari-compatible runtime backends.

  The matrix uses the consumer-facing questions we care about for Entr'acte:
  streaming, tool calls, approvals, token/cost telemetry, resume, cancel,
  workspace mode, and context-limit guarding.
  """

  alias Sari.Backend.{ClaudeCodeStreamJson, Fake, OpenCodeHttp}
  alias Sari.RuntimeCapabilities

  @backends [Fake, OpenCodeHttp, ClaudeCodeStreamJson]

  @matrix_capabilities [
    :streaming,
    :tool_calls,
    :approval_requests,
    :token_usage,
    :cost,
    :resume,
    :cancel,
    :workspace_mode,
    :context_limit
  ]

  @spec matrix_capabilities() :: [atom()]
  def matrix_capabilities, do: @matrix_capabilities

  @spec rows(keyword()) :: [map()]
  def rows(opts \\ []) do
    [codex_reference_row() | Enum.map(@backends, &backend_row(&1, opts))]
  end

  @spec report(keyword()) :: map()
  def report(opts \\ []) do
    %{
      generated_at: DateTime.utc_now(),
      capabilities: @matrix_capabilities,
      rows: rows(opts)
    }
  end

  @spec format_markdown(map()) :: String.t()
  def format_markdown(%{rows: rows}) do
    header =
      ["backend", "transport", "implemented" | Enum.map(@matrix_capabilities, &Atom.to_string/1)]
      |> Enum.join(" | ")

    separator =
      ["---", "---", "---" | Enum.map(@matrix_capabilities, fn _ -> "---" end)]
      |> Enum.join(" | ")

    body =
      Enum.map(rows, fn row ->
        capability_values = Enum.map(@matrix_capabilities, &format_value(row.capabilities[&1]))

        [row.backend, row.transport, row.implemented | capability_values]
        |> Enum.map(&to_string/1)
        |> Enum.join(" | ")
      end)
      |> Enum.join("\n")

    """
    # Sari Capability Matrix

    | #{header} |
    | #{separator} |
    #{Enum.map_join(String.split(body, "\n", trim: true), "\n", &("| " <> &1 <> " |"))}
    """
    |> String.trim()
  end

  defp backend_row(backend, opts) do
    capabilities = backend.capabilities(opts)

    %{
      backend: Atom.to_string(capabilities.backend),
      name: capabilities.name,
      version: capabilities.version,
      transport: Atom.to_string(capabilities.transport),
      implemented: true,
      capabilities: Map.new(@matrix_capabilities, &{&1, support(capabilities, &1)}),
      unsupported: normalize_map(capabilities.unsupported),
      metadata: normalize_map(capabilities.metadata)
    }
  end

  defp codex_reference_row do
    %{
      backend: "codex_app_server",
      name: "Codex app-server",
      version: nil,
      transport: "stdio_jsonrpc",
      implemented: false,
      capabilities: Map.new(@matrix_capabilities, &{&1, :reference}),
      unsupported: %{},
      metadata: %{
        role: :compatibility_reference,
        note: "External reference target consumed by Entr'acte today"
      }
    }
  end

  defp support(%RuntimeCapabilities{} = capabilities, :streaming),
    do: support_value(capabilities, :streaming_events)

  defp support(%RuntimeCapabilities{} = capabilities, :tool_calls),
    do: support_value(capabilities, :tool_calls) || support_value(capabilities, :dynamic_tools)

  defp support(%RuntimeCapabilities{} = capabilities, :approval_requests),
    do: support_value(capabilities, :approval_requests) || support_value(capabilities, :approvals)

  defp support(%RuntimeCapabilities{} = capabilities, :cancel),
    do: support_value(capabilities, :cancel) || support_value(capabilities, :cancellation)

  defp support(%RuntimeCapabilities{} = capabilities, capability),
    do: support_value(capabilities, capability) || false

  defp support_value(%RuntimeCapabilities{supports: supports}, capability) do
    Map.get(supports, capability)
  end

  defp normalize_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {normalize_key(key), normalize_value(value)} end)
  end

  defp normalize_value(map) when is_map(map), do: normalize_map(map)
  defp normalize_value(list) when is_list(list), do: Enum.map(list, &normalize_value/1)
  defp normalize_value(value), do: value

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: String.to_atom(key)
  defp normalize_key(key), do: key |> to_string() |> String.to_atom()

  defp format_value(true), do: "yes"
  defp format_value(false), do: "no"
  defp format_value(:degraded), do: "degraded"
  defp format_value(:reference), do: "reference"
  defp format_value(nil), do: "unknown"
  defp format_value(value), do: to_string(value)
end
