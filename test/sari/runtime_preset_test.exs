defmodule Sari.RuntimePresetTest do
  use ExUnit.Case, async: true

  alias Sari.Backend.{ClaudeCodeStreamJson, Fake, OpenCodeHttp}
  alias Sari.RuntimePreset

  test "lists Entr'acte-facing presets for Codex, fake, OpenCode, and Claude Code" do
    presets = RuntimePreset.all(repo_root: "/tmp/sari")

    assert Enum.map(presets, & &1.id) == [
             :codex_app_server,
             :fake,
             :opencode_lmstudio,
             :claude_code
           ]

    assert Enum.all?(presets, &(&1.runner == "app_server"))
    assert Enum.all?(presets, &(&1.compatibility_slot == "codex.command"))
  end

  test "keeps Codex as an external reference preset" do
    assert {:ok, preset} = RuntimePreset.get(:codex, repo_root: "/tmp/sari")

    assert preset.command == "codex app-server"
    refute Map.fetch!(preset, :runnable?)

    assert {:error, {:external_reference_preset, :codex_app_server}} =
             RuntimePreset.app_server_options(:codex)
  end

  test "resolves runnable Sari presets to backend modules and defaults" do
    assert {:ok, [backend: Fake, backend_opts: []]} =
             RuntimePreset.app_server_options(:fake, repo_root: "/tmp/sari")

    assert {:ok, [backend: OpenCodeHttp, backend_opts: opencode_opts]} =
             RuntimePreset.app_server_options(:opencode, repo_root: "/tmp/sari")

    assert opencode_opts[:base_url] == "http://127.0.0.1:41888"
    assert opencode_opts[:context_limit_tokens] == 8_192

    assert {:ok, [backend: ClaudeCodeStreamJson, backend_opts: claude_opts]} =
             RuntimePreset.app_server_options(:claude, repo_root: "/tmp/sari")

    assert claude_opts[:context_limit_tokens] == 200_000
    assert claude_opts[:turn_timeout_ms] == 300_000
    assert claude_opts[:dangerously_skip_permissions] == true
  end

  test "formats workflow YAML for Entr'acte's app_server compatibility slot" do
    assert {:ok, yaml} =
             RuntimePreset.format_workflow_yaml(:opencode_lmstudio, repo_root: "/tmp/sari")

    assert yaml =~ "agent:\n  runner: app_server"
    assert yaml =~ "codex:\n  command: >-"
    assert yaml =~ "/tmp/sari/scripts/sari_app_server --preset opencode_lmstudio"
  end
end
