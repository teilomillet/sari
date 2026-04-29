defmodule Sari.Backend.ClaudeCodeStreamJsonTest do
  use ExUnit.Case, async: true

  alias Sari.Backend.ClaudeCodeStreamJson
  alias Sari.Runtime

  test "streams Claude Code JSONL into normalized Sari events" do
    with_tmp(fn tmp ->
      trace = Path.join(tmp, "claude.args")
      fake_claude = fake_claude!(tmp, trace, :success)

      assert {:ok, session} =
               Runtime.start_session(
                 ClaudeCodeStreamJson,
                 %{"cwd" => tmp},
                 executable: fake_claude,
                 session_id: "not-a-uuid"
               )

      assert session.backend == :claude_code_stream_json
      assert session.cwd == tmp

      assert session.id =~
               ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

      assert {:ok, result} =
               Runtime.collect_turn(
                 ClaudeCodeStreamJson,
                 session,
                 [%{"type" => "text", "text" => "Reply exactly: sari-claude-ok"}],
                 executable: fake_claude,
                 turn_id: "claude-turn-1",
                 turn_timeout_ms: 1_000
               )

      assert Enum.map(result.events, & &1.type) == [
               :turn_started,
               :plan_update,
               :assistant_delta,
               :token_usage,
               :token_usage,
               :turn_completed
             ]

      assert [%{payload: %{text: "hello from claude"}}] =
               Enum.filter(result.events, &(&1.type == :assistant_delta))

      assert result.terminal.payload.result == "hello from claude"
      assert result.terminal.payload.total_cost_usd == 0.0123

      final_usage =
        result.events
        |> Enum.filter(&(&1.type == :token_usage))
        |> List.last()
        |> Map.fetch!(:payload)

      assert final_usage["input_tokens"] == 11
      assert final_usage["output_tokens"] == 3
      assert final_usage["total_tokens"] == 14
      assert final_usage["cost_usd"] == 0.0123

      args = File.read!(trace)
      assert args =~ "--output-format\nstream-json\n"
      assert args =~ "--include-partial-messages\n"
      assert args =~ "--include-hook-events\n"
      assert args =~ "--session-id\n#{session.id}\n"
      assert args =~ "Reply exactly: sari-claude-ok\n"
    end)
  end

  test "resume sessions launch Claude with --resume" do
    with_tmp(fn tmp ->
      trace = Path.join(tmp, "claude.args")
      fake_claude = fake_claude!(tmp, trace, :success)

      assert {:ok, session} =
               Runtime.resume_session(
                 ClaudeCodeStreamJson,
                 "existing-claude-session",
                 executable: fake_claude,
                 cwd: tmp
               )

      assert session.metadata.resumed == true

      assert {:ok, result} =
               Runtime.collect_turn(
                 ClaudeCodeStreamJson,
                 session,
                 "continue",
                 executable: fake_claude,
                 turn_id: "claude-turn-2",
                 turn_timeout_ms: 1_000
               )

      assert result.terminal.type == :turn_completed

      args = File.read!(trace)
      assert args =~ "--resume\nexisting-claude-session\n"
      refute args =~ "--session-id\n"
    end)
  end

  test "error result becomes a failed terminal event" do
    with_tmp(fn tmp ->
      trace = Path.join(tmp, "claude.args")
      fake_claude = fake_claude!(tmp, trace, :error)

      assert {:ok, session} =
               Runtime.start_session(ClaudeCodeStreamJson, %{"cwd" => tmp},
                 executable: fake_claude
               )

      assert {:ok, result} =
               Runtime.collect_turn(
                 ClaudeCodeStreamJson,
                 session,
                 "fail",
                 executable: fake_claude,
                 turn_id: "claude-turn-3",
                 turn_timeout_ms: 1_000
               )

      assert result.terminal.type == :turn_failed
      assert result.terminal.payload.is_error == true
      assert result.terminal.payload.result == "permission denied"
    end)
  end

  test "keeps Claude stderr out of JSONL parsing and reports it on process failure" do
    with_tmp(fn tmp ->
      success_trace = Path.join(tmp, "claude-success.args")
      stderr_success = fake_claude!(tmp, success_trace, :stderr_success)

      assert {:ok, session} =
               Runtime.start_session(ClaudeCodeStreamJson, %{"cwd" => tmp},
                 executable: stderr_success
               )

      assert {:ok, success} =
               Runtime.collect_turn(ClaudeCodeStreamJson, session, "stderr ok",
                 executable: stderr_success,
                 turn_id: "claude-stderr-ok",
                 turn_timeout_ms: 1_000
               )

      assert success.terminal.type == :turn_completed
      refute Enum.any?(success.events, &(&1.type == :error))

      error_trace = Path.join(tmp, "claude-error.args")
      stderr_error = fake_claude!(tmp, error_trace, :stderr_error)

      assert {:ok, error_session} =
               Runtime.start_session(ClaudeCodeStreamJson, %{"cwd" => tmp},
                 executable: stderr_error
               )

      assert {:ok, failed} =
               Runtime.collect_turn(ClaudeCodeStreamJson, error_session, "stderr fail",
                 executable: stderr_error,
                 turn_id: "claude-stderr-fail",
                 turn_timeout_ms: 1_000
               )

      assert failed.terminal.type == :turn_failed
      assert failed.terminal.payload.category == :process_exit
      assert failed.terminal.payload.details.exit_status == 42
      assert failed.terminal.payload.details.stderr =~ "stderr-only failure"
    end)
  end

  test "surfaces executable and cwd startup failures" do
    with_tmp(fn tmp ->
      missing = Path.join(tmp, "missing-claude")

      assert {:error, :claude_executable_not_found} =
               Runtime.start_session(ClaudeCodeStreamJson, %{"cwd" => tmp}, executable: missing)

      fake_claude = fake_claude!(tmp, Path.join(tmp, "claude.args"), :success)

      assert {:error, {:invalid_cwd, invalid_cwd}} =
               Runtime.start_session(ClaudeCodeStreamJson, %{"cwd" => Path.join(tmp, "missing")},
                 executable: fake_claude
               )

      assert invalid_cwd == Path.join(tmp, "missing")
    end)
  end

  defp with_tmp(fun) do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "sari-claude-code-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)

    try do
      fun.(tmp)
    after
      File.rm_rf(tmp)
    end
  end

  defp fake_claude!(tmp, trace, scenario) do
    path = Path.join(tmp, "claude")

    body =
      case scenario do
        :success ->
          """
          printf '{"type":"system","subtype":"init","session_id":"claude-fake-session","model":"fake-sonnet","tools":["Read","Bash"]}\\n'
          printf '{"type":"stream_event","session_id":"claude-fake-session","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"hello from claude"}}}\\n'
          printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"duplicate complete assistant message"}]}}\\n'
          printf '{"type":"stream_event","event":{"type":"message_delta","usage":{"output_tokens":3}}}\\n'
          printf '{"type":"result","subtype":"success","is_error":false,"session_id":"claude-fake-session","result":"hello from claude","usage":{"input_tokens":11,"output_tokens":3},"total_cost_usd":0.0123}\\n'
          """

        :error ->
          """
          printf '{"type":"result","subtype":"error","is_error":true,"session_id":"claude-fake-session","result":"permission denied","usage":{"input_tokens":5,"output_tokens":1},"total_cost_usd":0.001}\\n'
          """

        :stderr_success ->
          """
          printf 'debug stderr that is not json\n' >&2
          printf '{"type":"result","subtype":"success","is_error":false,"session_id":"claude-fake-session","result":"ok from stdout","usage":{"input_tokens":1,"output_tokens":1}}\n'
          """

        :stderr_error ->
          """
          printf 'stderr-only failure\n' >&2
          exit 42
          """
      end

    File.write!(path, """
    #!/bin/sh
    printf '%s\\n' "$@" > #{trace}
    #{body}
    """)

    File.chmod!(path, 0o755)
    path
  end
end
