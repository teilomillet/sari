defmodule Sari.RuntimeCapabilitiesTest do
  use ExUnit.Case, async: true

  alias Sari.{RuntimeCapabilities, RuntimeConformance}
  alias Sari.Backend.{ClaudeCodeStreamJson, Fake, OpenCodeHttp}

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

  test "runtime backends declare a complete Entr'acte-facing surface" do
    assert :ok = RuntimeConformance.verify_backend(Fake)
    assert :ok = RuntimeConformance.verify_backend(OpenCodeHttp)
    assert :ok = RuntimeConformance.verify_backend(ClaudeCodeStreamJson)
  end
end

defmodule Sari.CapabilityMatrixTest do
  use ExUnit.Case, async: true

  alias Sari.CapabilityMatrix

  test "reports the consumer-facing backend capability matrix" do
    report = CapabilityMatrix.report(context_limit_tokens: 8_192)

    assert CapabilityMatrix.matrix_capabilities() == [
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

    assert Enum.map(report.rows, & &1.backend) == [
             "codex_app_server",
             "fake",
             "opencode_http",
             "claude_code_stream_json"
           ]

    opencode = Enum.find(report.rows, &(&1.backend == "opencode_http"))
    assert opencode.capabilities.streaming == true
    assert opencode.capabilities.approval_requests == :degraded
    assert opencode.capabilities.cost == false
    assert opencode.capabilities.context_limit == :degraded
    assert opencode.metadata.context_limit_tokens == 8_192

    markdown = CapabilityMatrix.format_markdown(report)
    assert markdown =~ "| codex_app_server | stdio_jsonrpc | false | reference |"
    assert markdown =~ "| opencode_http | http_sse | true | yes | yes | degraded |"
  end
end
