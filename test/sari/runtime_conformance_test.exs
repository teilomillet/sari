defmodule Sari.RuntimeConformanceTest do
  use ExUnit.Case, async: true

  alias Sari.{Runtime, RuntimeConformance, RuntimeEvent}
  alias Sari.Backend.{ClaudeCodeStreamJson, Fake, OpenCodeHttp}

  @backends [Fake, OpenCodeHttp, ClaudeCodeStreamJson]

  test "all registered Sari backends satisfy declaration conformance" do
    for backend <- @backends do
      assert :ok = RuntimeConformance.verify_backend(backend, context_limit_tokens: 8_192)
    end
  end

  test "validates normalized turn event conformance" do
    {:ok, session} = Runtime.start_session(Fake, %{cwd: "/tmp/sari"}, session_id: "session-1")
    {:ok, result} = Runtime.collect_turn(Fake, session, "hello", turn_id: "turn-1")

    assert :ok = RuntimeConformance.verify_turn_events(result.events, session, "turn-1")
  end

  test "detects invalid turn event streams" do
    {:ok, session} = Runtime.start_session(Fake, %{}, session_id: "session-1")

    events = [
      RuntimeEvent.new(:turn_started, %{}, session_id: session.id, turn_id: "turn-1"),
      RuntimeEvent.new(:turn_completed, %{}, session_id: session.id, turn_id: "turn-1"),
      RuntimeEvent.new(:assistant_delta, %{text: "late"},
        session_id: session.id,
        turn_id: "turn-1"
      )
    ]

    assert {:error, failures} = RuntimeConformance.verify_turn_events(events, session, "turn-1")
    assert {:events_after_terminal, 1} in failures
  end
end
