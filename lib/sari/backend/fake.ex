defmodule Sari.Backend.Fake do
  @moduledoc """
  Deterministic backend for core contract tests.

  It proves the Sari runtime can run without any external RS process or network
  dependency. Production adapters should match this backend's normalized event
  contract before they add backend-specific transport code.
  """

  @behaviour Sari.RuntimeBackend

  alias Sari.{RuntimeCapabilities, RuntimeEvent, Session}

  @impl true
  def capabilities(_opts \\ []) do
    %RuntimeCapabilities{
      backend: :fake,
      name: "Sari fake backend",
      version: "0.1.0",
      transport: :in_memory,
      supports: %{
        sessions: true,
        resume: true,
        streaming_events: true,
        approvals: true,
        dynamic_tools: true,
        filesystem: true,
        command_execution: true,
        cancellation: true,
        token_usage: true,
        tool_calls: true,
        approval_requests: true,
        cost: true,
        cancel: true,
        workspace_mode: true,
        context_limit: true
      },
      unsupported: %{},
      metadata: %{deterministic: true}
    }
  end

  @impl true
  def start_session(params, opts \\ []) when is_map(params) do
    session_id = Keyword.get(opts, :session_id, Map.get(params, :session_id, "fake-session"))
    cwd = Map.get(params, :cwd) || Map.get(params, "cwd")

    {:ok,
     Session.new(session_id, :fake,
       cwd: cwd,
       metadata: %{
         backend: :fake,
         runtime: :sari,
         params: params
       }
     )}
  end

  @impl true
  def resume_session(session_id, opts \\ []) when is_binary(session_id) do
    cwd = Keyword.get(opts, :cwd)
    {:ok, Session.new(session_id, :fake, cwd: cwd, metadata: %{resumed: true})}
  end

  @impl true
  def start_turn(%Session{} = session, input, opts \\ []) do
    turn_id = Keyword.get(opts, :turn_id, "fake-turn")
    scripted_events = Keyword.get(opts, :events)

    events =
      case scripted_events do
        nil -> default_events(session, turn_id, input)
        events when is_list(events) -> Enum.map(events, &attach_ids(&1, session.id, turn_id))
      end

    {:ok, events}
  end

  @impl true
  def interrupt(%Session{}, turn_id, _opts \\ []) when is_binary(turn_id) do
    :ok
  end

  defp default_events(%Session{id: session_id}, turn_id, input) do
    [
      RuntimeEvent.new(:turn_started, %{input: input}, session_id: session_id, turn_id: turn_id),
      RuntimeEvent.new(:assistant_delta, %{text: "fake response"},
        session_id: session_id,
        turn_id: turn_id
      ),
      RuntimeEvent.new(:token_usage, %{input_tokens: 1, output_tokens: 2, total_tokens: 3},
        session_id: session_id,
        turn_id: turn_id
      ),
      RuntimeEvent.new(:turn_completed, %{result: "ok"}, session_id: session_id, turn_id: turn_id)
    ]
  end

  defp attach_ids(%RuntimeEvent{} = event, session_id, turn_id) do
    %RuntimeEvent{
      event
      | session_id: event.session_id || session_id,
        turn_id: event.turn_id || turn_id
    }
  end

  defp attach_ids(%{type: _type, payload: _payload} = event, session_id, turn_id) do
    event
    |> Map.put_new(:session_id, session_id)
    |> Map.put_new(:turn_id, turn_id)
  end
end
