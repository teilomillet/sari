defmodule Sari.RuntimeTest do
  use ExUnit.Case, async: true

  alias Sari.{Runtime, RuntimeEvent}
  alias Sari.Backend.Fake

  test "starts a session through a backend with required capabilities" do
    assert {:ok, session} =
             Runtime.start_session(Fake, %{cwd: "/tmp/example"}, session_id: "session-1")

    assert session.id == "session-1"
    assert session.backend == :fake
    assert session.cwd == "/tmp/example"
  end

  test "collects a normalized turn and requires one terminal event" do
    {:ok, session} = Runtime.start_session(Fake, %{}, session_id: "session-1")

    assert {:ok, result} = Runtime.collect_turn(Fake, session, "hello", turn_id: "turn-1")

    assert Enum.map(result.events, & &1.type) == [
             :turn_started,
             :assistant_delta,
             :token_usage,
             :turn_completed
           ]

    assert result.terminal.type == :turn_completed
    assert Enum.all?(result.events, &(&1.session_id == "session-1"))
    assert Enum.all?(result.events, &(&1.turn_id == "turn-1"))
  end

  test "fails closed when a backend does not emit a terminal turn event" do
    {:ok, session} = Runtime.start_session(Fake, %{}, session_id: "session-1")

    events = [
      RuntimeEvent.new(:turn_started, %{}),
      RuntimeEvent.new(:assistant_delta, %{text: "partial"})
    ]

    assert {:error, {:missing_terminal_event, emitted}} =
             Runtime.collect_turn(Fake, session, "hello", events: events)

    assert Enum.map(emitted, & &1.type) == [:turn_started, :assistant_delta]
  end

  test "fails closed when a backend emits multiple terminal events" do
    {:ok, session} = Runtime.start_session(Fake, %{}, session_id: "session-1")

    events = [
      RuntimeEvent.new(:turn_started, %{}),
      RuntimeEvent.new(:turn_completed, %{}),
      RuntimeEvent.new(:turn_failed, %{reason: "too late"})
    ]

    assert {:error, {:multiple_terminal_events, terminals}} =
             Runtime.collect_turn(Fake, session, "hello", events: events)

    assert Enum.map(terminals, & &1.type) == [:turn_completed, :turn_failed]
  end

  test "rejects turns that exceed a configured context limit before backend execution" do
    {:ok, session} = Runtime.start_session(Fake, %{}, session_id: "session-budget")

    assert {:error, %Sari.RuntimeError{} = error} =
             Runtime.collect_turn(Fake, session, String.duplicate("x", 100),
               context_limit_tokens: 4,
               reserved_output_tokens: 1
             )

    assert error.category == :context_limit_exceeded
    assert error.backend == :fake
    assert error.stage == :input_budget
    assert error.details.total_tokens > error.details.limit_tokens
  end
end
