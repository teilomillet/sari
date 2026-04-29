defmodule Sari.CLI do
  @moduledoc """
  Minimal CLI entry point for the Sari app-server facade.
  """

  alias Sari.AppServer.Protocol
  alias Sari.Backend.{ClaudeCodeStreamJson, Fake, OpenCodeHttp}
  alias Sari.Mcp.EntracteTools
  alias Sari.RuntimePreset

  @spec main([String.t()]) :: :ok
  def main(["app-server" | args]) do
    case app_server_options(args) do
      {:ok, opts} ->
        loop(Protocol.new(opts))

      {:error, reason} ->
        IO.puts(:stderr, "sari app-server config error: #{reason}")
        System.halt(2)
    end
  end

  def main(["mcp", "entracte-tools" | _args]) do
    EntracteTools.run()
  end

  def main(_args) do
    IO.puts(
      :stderr,
      "usage: sari app-server [--preset fake|opencode_lmstudio|claude_code] [--backend fake|opencode_http|claude_code_stream_json] [backend options]\n" <>
        "       sari mcp entracte-tools"
    )
  end

  defp app_server_options(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          backend: :string,
          preset: :string,
          base_url: :string,
          executable: :string,
          event_timeout_ms: :integer,
          request_timeout_ms: :integer,
          connect_timeout_ms: :integer,
          turn_timeout_ms: :integer,
          max_events: :integer,
          context_limit: :integer,
          reserved_output_tokens: :integer,
          no_reply: :boolean,
          model: :string,
          permission_mode: :string,
          tools: :string,
          allowed_tools: :string,
          disallowed_tools: :string,
          system_prompt: :string,
          append_system_prompt: :string,
          permission_prompt_tool: :string,
          bare: :boolean,
          verbose: :boolean,
          partial_messages: :boolean,
          hook_events: :boolean,
          dangerously_skip_permissions: :boolean
        ]
      )

    cond do
      invalid != [] ->
        {:error, "invalid options: #{inspect(invalid)}"}

      Keyword.has_key?(opts, :preset) and Keyword.has_key?(opts, :backend) ->
        {:error, "use either --preset or --backend, not both"}

      true ->
        with {:ok, backend, preset_backend_opts} <- backend_config(opts) do
          {:ok,
           [
             backend: backend,
             backend_opts:
               preset_backend_opts
               |> put_opt(
                 :executable,
                 Keyword.get(opts, :executable) || backend_env(backend, "EXECUTABLE")
               )
               |> put_opt(
                 :base_url,
                 Keyword.get(opts, :base_url) || env("SARI_OPENCODE_BASE_URL")
               )
               |> put_opt(
                 :event_timeout_ms,
                 Keyword.get(opts, :event_timeout_ms) || env_int("SARI_OPENCODE_EVENT_TIMEOUT_MS")
               )
               |> put_opt(
                 :request_timeout_ms,
                 Keyword.get(opts, :request_timeout_ms) ||
                   env_int("SARI_OPENCODE_REQUEST_TIMEOUT_MS")
               )
               |> put_opt(
                 :connect_timeout_ms,
                 Keyword.get(opts, :connect_timeout_ms) ||
                   env_int("SARI_OPENCODE_CONNECT_TIMEOUT_MS")
               )
               |> put_opt(
                 :turn_timeout_ms,
                 Keyword.get(opts, :turn_timeout_ms) ||
                   backend_env_int(backend, "TURN_TIMEOUT_MS")
               )
               |> put_opt(
                 :max_events,
                 Keyword.get(opts, :max_events) || backend_env_int(backend, "MAX_EVENTS")
               )
               |> put_opt(
                 :context_limit_tokens,
                 Keyword.get(opts, :context_limit) ||
                   backend_env_int(backend, "CONTEXT_LIMIT_TOKENS")
               )
               |> put_opt(
                 :reserved_output_tokens,
                 Keyword.get(opts, :reserved_output_tokens) ||
                   backend_env_int(backend, "RESERVED_OUTPUT_TOKENS")
               )
               |> put_opt(:no_reply, Keyword.get(opts, :no_reply))
               |> put_opt(:model, Keyword.get(opts, :model) || backend_env(backend, "MODEL"))
               |> put_opt(
                 :permission_mode,
                 Keyword.get(opts, :permission_mode) || backend_env(backend, "PERMISSION_MODE")
               )
               |> put_opt(:tools, Keyword.get(opts, :tools) || backend_env(backend, "TOOLS"))
               |> put_opt(
                 :allowed_tools,
                 Keyword.get(opts, :allowed_tools) || backend_env(backend, "ALLOWED_TOOLS")
               )
               |> put_opt(
                 :disallowed_tools,
                 Keyword.get(opts, :disallowed_tools) || backend_env(backend, "DISALLOWED_TOOLS")
               )
               |> put_opt(
                 :system_prompt,
                 Keyword.get(opts, :system_prompt) || backend_env(backend, "SYSTEM_PROMPT")
               )
               |> put_opt(
                 :append_system_prompt,
                 Keyword.get(opts, :append_system_prompt) ||
                   backend_env(backend, "APPEND_SYSTEM_PROMPT")
               )
               |> put_opt(
                 :permission_prompt_tool,
                 Keyword.get(opts, :permission_prompt_tool) ||
                   backend_env(backend, "PERMISSION_PROMPT_TOOL")
               )
               |> put_opt(:bare, opt_or_env(opts, :bare, backend_env_bool(backend, "BARE")))
               |> put_opt(
                 :verbose,
                 opt_or_env(opts, :verbose, backend_env_bool(backend, "VERBOSE"))
               )
               |> put_opt(
                 :partial_messages,
                 opt_or_env(
                   opts,
                   :partial_messages,
                   backend_env_bool(backend, "PARTIAL_MESSAGES")
                 )
               )
               |> put_opt(
                 :hook_events,
                 opt_or_env(opts, :hook_events, backend_env_bool(backend, "HOOK_EVENTS"))
               )
               |> put_opt(
                 :dangerously_skip_permissions,
                 opt_or_env(
                   opts,
                   :dangerously_skip_permissions,
                   backend_env_bool(backend, "DANGEROUSLY_SKIP_PERMISSIONS")
                 )
               )
           ]}
        end
    end
  end

  defp backend_config(opts) do
    case Keyword.get(opts, :preset) || env("SARI_PRESET") do
      preset when is_binary(preset) and preset != "" ->
        preset_backend_config(preset)

      _ ->
        with {:ok, backend} <-
               backend_module(Keyword.get(opts, :backend) || env("SARI_BACKEND") || "fake") do
          {:ok, backend, []}
        end
    end
  end

  defp preset_backend_config(preset) do
    case RuntimePreset.app_server_options(preset) do
      {:ok, opts} ->
        {:ok, Keyword.fetch!(opts, :backend), Keyword.get(opts, :backend_opts, [])}

      {:error, {:external_reference_preset, preset_id}} ->
        {:error,
         "#{preset_id} is an external Entr'acte preset; run its command directly instead of `sari app-server --preset #{preset_id}`"}

      {:error, reason} ->
        {:error, "unsupported preset: #{inspect(reason)}"}
    end
  end

  defp backend_module(value) do
    case value |> to_string() |> String.trim() |> String.downcase() do
      "fake" -> {:ok, Fake}
      "claude" -> {:ok, ClaudeCodeStreamJson}
      "claude_code" -> {:ok, ClaudeCodeStreamJson}
      "claude_code_stream_json" -> {:ok, ClaudeCodeStreamJson}
      "opencode" -> {:ok, OpenCodeHttp}
      "opencode_http" -> {:ok, OpenCodeHttp}
      other -> {:error, "unsupported backend: #{other}"}
    end
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, _key, ""), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp opt_or_env(opts, key, env_value) do
    if Keyword.has_key?(opts, key), do: Keyword.fetch!(opts, key), else: env_value
  end

  defp env(name) do
    case System.get_env(name) do
      nil -> nil
      value -> String.trim(value)
    end
  end

  defp env_int(name) do
    case env(name) do
      nil ->
        nil

      "" ->
        nil

      value ->
        case Integer.parse(value) do
          {integer, ""} -> integer
          _ -> nil
        end
    end
  end

  defp backend_env(ClaudeCodeStreamJson, suffix), do: env("SARI_CLAUDE_" <> suffix)
  defp backend_env(OpenCodeHttp, suffix), do: env("SARI_OPENCODE_" <> suffix)
  defp backend_env(_backend, _suffix), do: nil

  defp backend_env_int(backend, suffix) do
    case backend do
      ClaudeCodeStreamJson -> env_int("SARI_CLAUDE_" <> suffix)
      OpenCodeHttp -> env_int("SARI_OPENCODE_" <> suffix)
      _ -> nil
    end
  end

  defp backend_env_bool(backend, suffix) do
    case backend_env(backend, suffix) do
      nil -> nil
      "" -> nil
      value -> env_bool_value(value)
    end
  end

  defp env_bool_value(value) do
    case value |> String.trim() |> String.downcase() do
      truthy when truthy in ["1", "true", "yes", "on"] -> true
      falsey when falsey in ["0", "false", "no", "off"] -> false
      _ -> nil
    end
  end

  defp loop(state) do
    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "stdin read failed: #{inspect(reason)}")

      line ->
        {next_state, output_lines} = Protocol.handle_json_line_stream(state, line)

        Enum.each(output_lines, fn output ->
          IO.write(output)
          IO.write("\n")
        end)

        loop(next_state)
    end
  end
end
