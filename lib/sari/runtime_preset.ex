defmodule Sari.RuntimePreset do
  @moduledoc """
  Entr'acte-facing runtime presets for Sari and the Codex reference path.

  Entr'acte still launches app-server runtimes through the compatibility
  `codex.command` slot. Presets keep that path explicit while moving backend
  selection into Sari configuration.
  """

  alias Sari.Backend.{ClaudeCodeStreamJson, Fake, OpenCodeHttp}

  @type id :: :codex_app_server | :fake | :opencode_lmstudio | :claude_code

  @preset_order [:codex_app_server, :fake, :opencode_lmstudio, :claude_code]

  @spec ids() :: [id()]
  def ids, do: @preset_order

  @spec all(keyword()) :: [map()]
  def all(opts \\ []) do
    Enum.map(@preset_order, &get!(&1, opts))
  end

  @spec get(String.t() | atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def get(id, opts \\ []) do
    with {:ok, normalized_id} <- normalize_id(id) do
      {:ok, build(normalized_id, opts)}
    end
  end

  @spec get!(String.t() | atom(), keyword()) :: map()
  def get!(id, opts \\ []) do
    case get(id, opts) do
      {:ok, preset} -> preset
      {:error, reason} -> raise ArgumentError, "unknown Sari runtime preset: #{inspect(reason)}"
    end
  end

  @spec app_server_options(String.t() | atom(), keyword()) ::
          {:ok, keyword()} | {:error, term()}
  def app_server_options(id, opts \\ []) do
    case get(id, opts) do
      {:ok, %{runnable?: true, backend_module: backend, backend_opts: backend_opts}} ->
        {:ok, [backend: backend, backend_opts: backend_opts]}

      {:ok, %{id: preset_id}} ->
        {:error, {:external_reference_preset, preset_id}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec workflow_config(String.t() | atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def workflow_config(id, opts \\ []) do
    case get(id, opts) do
      {:ok, preset} ->
        {:ok,
         %{
           "agent" => %{"runner" => "app_server"},
           "codex" => %{"command" => preset.command}
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec format_workflow_yaml(String.t() | atom(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def format_workflow_yaml(id, opts \\ []) do
    case workflow_config(id, opts) do
      {:ok, %{"codex" => %{"command" => command}}} ->
        {:ok,
         """
         agent:
           runner: app_server
         codex:
           command: >-
             #{command}
         """
         |> String.trim()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build(:codex_app_server, _opts) do
    %{
      id: :codex_app_server,
      aliases: ["codex", "codex_app_server"],
      name: "Codex app-server reference",
      runner: "app_server",
      compatibility_slot: "codex.command",
      backend: :codex_app_server,
      backend_module: nil,
      backend_opts: [],
      runnable?: false,
      command: "codex app-server",
      smoke: "codex app-server generate-json-schema --out /tmp/codex-app-server-schema",
      notes: [
        "External reference runtime already consumed by Entr'acte.",
        "Sari does not wrap Codex; it emulates this app-server boundary."
      ]
    }
  end

  defp build(:fake, opts) do
    script = script_path(opts)

    %{
      id: :fake,
      aliases: ["fake", "sari_fake"],
      name: "Sari fake backend",
      runner: "app_server",
      compatibility_slot: "codex.command",
      backend: :fake,
      backend_module: Fake,
      backend_opts: [],
      runnable?: true,
      command: "#{script} --preset fake",
      smoke: "mix test test/sari/app_server_contract_fixture_test.exs",
      notes: [
        "Deterministic Sari backend for CI and Entr'acte contract tests.",
        "No external credentials, network, or model server required."
      ]
    }
  end

  defp build(:opencode_lmstudio, opts) do
    script = script_path(opts)

    %{
      id: :opencode_lmstudio,
      aliases: ["opencode", "opencode_http", "opencode_lmstudio", "lmstudio"],
      name: "OpenCode over LM Studio",
      runner: "app_server",
      compatibility_slot: "codex.command",
      backend: :opencode_http,
      backend_module: OpenCodeHttp,
      backend_opts: [
        base_url: "http://127.0.0.1:41888",
        context_limit_tokens: 8_192,
        reserved_output_tokens: 512
      ],
      runnable?: true,
      command:
        "SARI_OPENCODE_BASE_URL=${SARI_OPENCODE_BASE_URL:-http://127.0.0.1:41888} #{script} --preset opencode_lmstudio",
      smoke:
        "SARI_OPENCODE_BASE_URL=http://127.0.0.1:41888 mix run scripts/sari_app_server_entracte_pr2_smoke.exs",
      notes: [
        "Requires a running `opencode serve` endpoint.",
        "For LM Studio, load the model with enough context for OpenCode's tool prompt."
      ]
    }
  end

  defp build(:claude_code, opts) do
    script = script_path(opts)

    %{
      id: :claude_code,
      aliases: ["claude", "claude_code", "claude_code_stream_json"],
      name: "Claude Code stream-json",
      runner: "app_server",
      compatibility_slot: "codex.command",
      backend: :claude_code_stream_json,
      backend_module: ClaudeCodeStreamJson,
      backend_opts: [
        context_limit_tokens: 200_000,
        reserved_output_tokens: 1_024,
        turn_timeout_ms: 300_000
      ],
      runnable?: true,
      command: "#{script} --preset claude_code",
      smoke:
        ~s(SARI_BACKEND=claude_code_stream_json SARI_ENTRACTE_PROMPT="Reply exactly: sari-claude-ok" mix run scripts/sari_app_server_entracte_pr2_smoke.exs),
      notes: [
        "Requires `claude` CLI auth in the launching user environment.",
        "Uses one Claude Code stream-json subprocess per turn until Sari has stop-session semantics."
      ]
    }
  end

  defp normalize_id(id) when is_atom(id), do: normalize_id(Atom.to_string(id))

  defp normalize_id(id) when is_binary(id) do
    normalized =
      id
      |> String.trim()
      |> String.downcase()
      |> String.replace("-", "_")

    cond do
      normalized in ["codex", "codex_app_server"] ->
        {:ok, :codex_app_server}

      normalized in ["fake", "sari_fake"] ->
        {:ok, :fake}

      normalized in ["opencode", "opencode_http", "opencode_lmstudio", "lmstudio"] ->
        {:ok, :opencode_lmstudio}

      normalized in ["claude", "claude_code", "claude_code_stream_json"] ->
        {:ok, :claude_code}

      true ->
        {:error, {:unknown_preset, id}}
    end
  end

  defp script_path(opts) do
    opts
    |> Keyword.get(:script_path, Path.join(repo_root(opts), "scripts/sari_app_server"))
    |> Path.expand()
  end

  defp repo_root(opts) do
    Keyword.get(opts, :repo_root, Path.expand("../..", __DIR__))
  end
end
