defmodule Sari.ProfileTest do
  use ExUnit.Case, async: true

  alias Sari.Profile

  test "profiles app-server fake scenario with USL-ready measurements" do
    report =
      Profile.run(
        scenario: :app_server_fake,
        concurrency_levels: [1, 2],
        iterations: 3,
        warmup_iterations: 1
      )

    assert report.scenario == :app_server_fake
    assert %DateTime{} = report.generated_at
    assert Enum.map(report.measurements, & &1.concurrency) == [1, 2]

    for measurement <- report.measurements do
      assert measurement.operations == measurement.concurrency * 3
      assert measurement.successes == measurement.operations
      assert measurement.errors == 0
      assert measurement.output_messages == measurement.operations * 6
      assert measurement.duration_us > 0
      assert measurement.throughput_ops_per_sec > 0
      assert measurement.latency_us.p50 >= 0
      assert measurement.latency_us.p95 >= measurement.latency_us.p50
      assert is_integer(measurement.reductions.per_op)
      assert is_integer(measurement.memory_bytes.delta)
      assert is_integer(measurement.mailbox.delta)
    end
  end

  test "formats profile report as markdown" do
    report =
      Profile.run(
        scenario: :app_server_fake,
        concurrency_levels: [1],
        iterations: 1,
        warmup_iterations: 0
      )

    markdown = Profile.format_markdown(report)

    assert markdown =~ "# Sari profile: app_server_fake"
    assert markdown =~ "| N | ops | ok | errors | ops/s |"
    assert markdown =~ "| 1 | 1 | 1 | 0 |"
  end

  test "formats profile report as JSON" do
    report =
      Profile.run(
        scenario: :app_server_fake,
        concurrency_levels: [1],
        iterations: 1,
        warmup_iterations: 0
      )

    assert {:ok, decoded} = Sari.Json.decode(Profile.format_json(report))
    assert decoded["scenario"] == "app_server_fake"
    assert [%{"concurrency" => 1}] = decoded["measurements"]
  end

  test "formats OpenCode probe report as markdown" do
    report = %{
      scenario: :opencode_probe,
      generated_at: DateTime.utc_now(),
      measurements: [
        %{
          scenario: :opencode_probe,
          command: ["opencode", "serve"],
          host: "127.0.0.1",
          port: 45_555,
          version: "1.14.29",
          started: true,
          ready: true,
          cold_start_us: 12_345,
          endpoint_measurements: [
            %{
              method: :get,
              path: "/global/health",
              status: 200,
              ok: true,
              duration_us: 100,
              bytes: 37,
              error: nil
            }
          ],
          sse_measurement: %{
            path: "/global/event",
            status: 200,
            ok: true,
            duration_us: 55,
            bytes: 64,
            first_event: "data: {\"payload\":{\"type\":\"server.connected\"}}",
            error: nil
          },
          session_lifecycle: %{
            created: true,
            session_id: "ses_test",
            create: %{
              method: :post,
              path: "/session",
              status: 200,
              ok: true,
              duration_us: 120,
              bytes: 80,
              error: nil
            },
            messages: %{
              method: :get,
              path: "/session/ses_test/message",
              status: 200,
              ok: true,
              duration_us: 80,
              bytes: 2,
              error: nil
            },
            server_status: %{
              method: :get,
              path: "/session/status",
              status: 200,
              ok: true,
              duration_us: 70,
              bytes: 2,
              error: nil
            },
            prompt_async: %{
              method: :post,
              path: "/session/{sessionID}/prompt_async",
              status: nil,
              ok: false,
              duration_us: 0,
              bytes: 0,
              error: "not_attempted"
            },
            delete: %{
              method: :delete,
              path: "/session/ses_test",
              status: 200,
              ok: true,
              duration_us: 60,
              bytes: 0,
              error: nil
            },
            error: nil
          },
          stdout_sample: ["opencode server listening on http://127.0.0.1:45555"],
          error: nil
        }
      ]
    }

    markdown = Profile.format_markdown(report)

    assert markdown =~ "# Sari profile: opencode_probe"
    assert markdown =~ "version: `1.14.29`"
    assert markdown =~ "cold_start_us: `12345`"
    assert markdown =~ "| get | /global/health | 200 | true | 100 | 37 |  |"
    assert markdown =~ "## SSE"
    assert markdown =~ "server.connected"
    assert markdown =~ "## session lifecycle"
    assert markdown =~ "| create | post | /session | 200 | true | 120 | 80 |  |"
  end

  test "formats Claude Code probe report as markdown" do
    report = %{
      scenario: :claude_code_probe,
      generated_at: DateTime.utc_now(),
      measurements: [
        %{
          scenario: :claude_code_probe,
          command: ["claude", "-p", "--output-format", "stream-json"],
          cwd: "/tmp/sari",
          version: "2.1.92 (Claude Code)",
          ready: true,
          prompt_provided: true,
          version_measurement: %{
            step: :version,
            ok: true,
            duration_us: 100,
            output: "2.1.92 (Claude Code)",
            error: nil
          },
          turn: %{
            attempted: true,
            ok: true,
            session_id: "claude-session",
            session_duration_us: 20,
            duration_us: 300,
            event_count: 4,
            assistant_text: "sari-claude-ok",
            terminal: :turn_completed,
            token_usage: %{
              "input_tokens" => 10,
              "output_tokens" => 3,
              "total_tokens" => 13,
              "cost_usd" => 0.001
            },
            error: nil
          },
          error: nil
        }
      ]
    }

    markdown = Profile.format_markdown(report)

    assert markdown =~ "# Sari profile: claude_code_probe"
    assert markdown =~ "version: `2.1.92 (Claude Code)`"
    assert markdown =~ "assistant_text: `sari-claude-ok`"
    assert markdown =~ "input_tokens: `10`"
    assert markdown =~ "cost_usd: `0.001`"
  end
end
