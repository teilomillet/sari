defmodule Sari.Probe.ClaudeCodeTest do
  use ExUnit.Case, async: true

  alias Sari.Probe.ClaudeCode

  test "records missing claude executable as probe data" do
    result = ClaudeCode.run(executable: nil)

    assert result.scenario == :claude_code_probe
    refute result.ready
    assert result.error == "claude executable not found"
    assert is_nil(result.version)
    refute result.turn.attempted
    assert result.turn.error == "not_attempted"
  end

  test "runs a prompted probe through the Sari Claude backend" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "sari-claude-probe-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)

    try do
      fake = Path.join(tmp, "claude")

      File.write!(fake, """
      #!/bin/sh
      if [ "$1" = "--version" ]; then
        printf '2.1.92 (Claude Code)\\n'
        exit 0
      fi
      printf '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"probe-ok"}}}\\n'
      printf '{"type":"result","subtype":"success","is_error":false,"session_id":"claude-fake","result":"probe-ok","usage":{"input_tokens":7,"output_tokens":2},"total_cost_usd":0.004}\\n'
      """)

      File.chmod!(fake, 0o755)

      result =
        ClaudeCode.run(
          executable: fake,
          cwd: tmp,
          prompt: "Reply exactly: probe-ok",
          turn_timeout_ms: 1_000
        )

      assert result.ready
      assert result.version == "2.1.92 (Claude Code)"
      assert result.turn.attempted
      assert result.turn.ok
      assert result.turn.assistant_text == "probe-ok"
      assert result.turn.token_usage["input_tokens"] == 7
      assert result.turn.token_usage["output_tokens"] == 2
      assert result.turn.token_usage["total_tokens"] == 9
      assert result.turn.token_usage["cost_usd"] == 0.004
    after
      File.rm_rf(tmp)
    end
  end
end
