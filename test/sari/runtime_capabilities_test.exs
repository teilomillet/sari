defmodule Sari.RuntimeCapabilitiesTest do
  use ExUnit.Case, async: true

  alias Sari.RuntimeCapabilities
  alias Sari.Backend.{ClaudeCodeStreamJson, OpenCodeHttp}

  test "declares required capabilities" do
    assert RuntimeCapabilities.required_capabilities() == [:sessions, :streaming_events]
  end

  test "detects missing required capabilities" do
    capabilities = %RuntimeCapabilities{
      backend: :incomplete,
      supports: %{sessions: true}
    }

    assert RuntimeCapabilities.validate_required(capabilities) ==
             {:error, {:missing_capabilities, [:streaming_events]}}
  end

  test "OpenCode HTTP adapter declares degraded capabilities explicitly" do
    capabilities = OpenCodeHttp.capabilities()

    assert RuntimeCapabilities.supports?(capabilities, :sessions)
    assert RuntimeCapabilities.supports?(capabilities, :streaming_events)
    assert RuntimeCapabilities.supports?(capabilities, :dynamic_tools)
    refute RuntimeCapabilities.fully_supports?(capabilities, :dynamic_tools)
    assert RuntimeCapabilities.unsupported_reason(capabilities, :dynamic_tools)
  end

  test "Claude Code stream-json adapter declares approval and dynamic tool degradation explicitly" do
    capabilities = ClaudeCodeStreamJson.capabilities()

    assert RuntimeCapabilities.supports?(capabilities, :sessions)
    assert RuntimeCapabilities.supports?(capabilities, :streaming_events)
    assert RuntimeCapabilities.supports?(capabilities, :approvals)
    refute RuntimeCapabilities.fully_supports?(capabilities, :approvals)
    assert RuntimeCapabilities.unsupported_reason(capabilities, :approvals)
    assert RuntimeCapabilities.unsupported_reason(capabilities, :dynamic_tools)
  end
end
