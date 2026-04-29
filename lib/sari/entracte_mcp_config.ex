defmodule Sari.EntracteMcpConfig do
  @moduledoc """
  Builds Claude Code MCP config files for Entr'acte dynamic tools.
  """

  alias Sari.{Json, Mcp.EntracteTools}

  @server_name "entracte"

  @spec maybe_write(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def maybe_write(params, opts \\ [])

  def maybe_write(params, opts) when is_map(params) and is_list(opts) do
    dynamic_tools = Map.get(params, "dynamicTools") || Map.get(params, :dynamicTools) || []

    if entracte_tool_requested?(dynamic_tools) do
      with {:ok, command} <- mcp_command(opts),
           {:ok, path} <- write_config(command) do
        {:ok,
         %{
           mcp_config_path: path,
           mcp_server: @server_name,
           mcp_tools: requested_tool_names(dynamic_tools)
         }}
      end
    else
      {:ok, %{}}
    end
  end

  def maybe_write(_params, _opts), do: {:ok, %{}}

  @spec default_system_prompt(map()) :: String.t() | nil
  def default_system_prompt(%{mcp_config_path: path}) when is_binary(path) do
    """
    Entr'acte dynamic tools are available through the Claude Code MCP server named #{@server_name}.
    When the workflow refers to `linear_graphql`, use the #{@server_name} MCP Linear GraphQL tool.
    When the workflow refers to `gitlab_coverage`, use the #{@server_name} MCP GitLab coverage tool.
    Treat MCP tool results as authoritative and keep using the tracked workflow exactly as written.
    """
    |> String.trim()
  end

  def default_system_prompt(_metadata), do: nil

  defp entracte_tool_requested?(dynamic_tools) when is_list(dynamic_tools) do
    requested = MapSet.new(requested_tool_names(dynamic_tools))
    supported = MapSet.new(supported_tool_names())

    not MapSet.disjoint?(requested, supported)
  end

  defp entracte_tool_requested?(_dynamic_tools), do: false

  defp requested_tool_names(dynamic_tools) when is_list(dynamic_tools) do
    dynamic_tools
    |> Enum.map(fn
      %{"name" => name} when is_binary(name) -> name
      %{name: name} when is_binary(name) -> name
      _tool -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp supported_tool_names do
    EntracteTools.tool_specs()
    |> Enum.map(& &1["name"])
  end

  defp mcp_command(opts) do
    value =
      Keyword.get(opts, :entracte_mcp_command) ||
        System.get_env("SARI_ENTRACTE_MCP_COMMAND") ||
        default_mcp_command()

    case value do
      command when is_binary(command) and command != "" -> {:ok, command}
      _ -> {:error, :missing_entracte_mcp_command}
    end
  end

  defp default_mcp_command do
    case System.get_env("SARI_HOME") do
      home when is_binary(home) and home != "" ->
        Path.join([home, "scripts", "sari_mcp_entracte_tools"])

      _ ->
        nil
    end
  end

  defp write_config(command) do
    path =
      Path.join(
        System.tmp_dir!(),
        "sari-entracte-mcp-#{System.unique_integer([:positive])}.json"
      )

    config = %{
      "mcpServers" => %{
        @server_name => %{
          "command" => command,
          "args" => [],
          "env" => %{
            "SARI_COMPILE" => "0"
          }
        }
      }
    }

    case File.write(path, Json.encode!(config)) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:mcp_config_write_failed, reason}}
    end
  end
end
