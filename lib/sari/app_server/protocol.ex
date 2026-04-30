defmodule Sari.AppServer.Protocol do
  @moduledoc """
  Bounded app-server-compatible protocol state machine.

  This is intentionally smaller than the full Codex app-server protocol. It
  implements the subset Entr'acte already consumes so a Sari command can later
  sit in the existing workflow command slot.
  """

  alias Sari.{Json, Runtime, RuntimeCapabilities, RuntimeError, RuntimeEvent, Session}
  alias Sari.Backend.Fake

  @type output :: map()

  @type t :: %__MODULE__{
          backend: module(),
          backend_opts: keyword(),
          sessions: %{optional(String.t()) => Session.t()},
          next_thread: non_neg_integer(),
          next_turn: non_neg_integer()
        }

  defstruct backend: Fake,
            backend_opts: [],
            sessions: %{},
            next_thread: 1,
            next_turn: 1

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      backend: Keyword.get(opts, :backend, Fake),
      backend_opts: Keyword.get(opts, :backend_opts, []),
      sessions: %{},
      next_thread: 1,
      next_turn: 1
    }
  end

  @spec handle_json_line(t(), String.t()) :: {t(), [String.t()]}
  def handle_json_line(%__MODULE__{} = state, line) when is_binary(line) do
    case Json.decode(line) do
      {:ok, message} ->
        handle_message(state, message) |> encode_outputs()

      {:error, reason} ->
        {state, [Json.encode!(error_response(nil, :parse_error, inspect(reason)))]}
    end
  end

  @spec handle_json_line_stream(t(), String.t()) :: {t(), Enumerable.t()}
  def handle_json_line_stream(%__MODULE__{} = state, line) when is_binary(line) do
    case Json.decode(line) do
      {:ok, %{"method" => "turn/start", "id" => id} = message} ->
        handle_turn_start_stream(state, id, message)

      {:ok, message} ->
        handle_message(state, message) |> encode_outputs()

      {:error, reason} ->
        {state, [Json.encode!(error_response(nil, :parse_error, inspect(reason)))]}
    end
  end

  @spec handle_message(t(), map()) :: {t(), [output()]}
  def handle_message(%__MODULE__{} = state, %{"method" => "initialize", "id" => id}) do
    capabilities = Runtime.capabilities(state.backend, state.backend_opts)

    result = %{
      "serverInfo" => %{
        "name" => "sari",
        "version" => "0.1.0"
      },
      "capabilities" => encode_capabilities(capabilities)
    }

    {state, [result_response(id, result)]}
  end

  def handle_message(%__MODULE__{} = state, %{"method" => "initialized"}) do
    {state, []}
  end

  def handle_message(%__MODULE__{} = state, %{"method" => "thread/start", "id" => id} = message) do
    params = Map.get(message, "params", %{})
    session_id = Map.get(params, "threadId") || "sari-thread-#{state.next_thread}"
    backend_opts = Keyword.put(state.backend_opts, :session_id, session_id)

    case Runtime.start_session(state.backend, params, backend_opts) do
      {:ok, %Session{} = session} ->
        next_state = %{
          state
          | sessions: Map.put(state.sessions, session.id, session),
            next_thread: state.next_thread + 1
        }

        result = %{
          "thread" => %{
            "id" => session.id,
            "status" => "ready",
            "metadata" => session.metadata
          },
          "cwd" => session.cwd,
          "model" => "sari",
          "modelProvider" => backend_name(state.backend)
        }

        {next_state, [result_response(id, result)]}

      {:error, reason} ->
        {state, [error_response(id, :thread_start_failed, inspect(reason))]}
    end
  end

  def handle_message(%__MODULE__{} = state, %{"method" => "turn/start", "id" => id} = message) do
    params = Map.get(message, "params", %{})
    thread_id = Map.get(params, "threadId")
    input = Map.get(params, "input", [])

    with %Session{} = session <- Map.get(state.sessions, thread_id) do
      turn_id = "sari-turn-#{state.next_turn}"

      case Runtime.stream_turn(
             state.backend,
             session,
             input,
             Keyword.put(state.backend_opts, :turn_id, turn_id)
           ) do
        {:ok, stream} ->
          events = Enum.to_list(stream)
          terminal_count = Enum.count(events, &RuntimeEvent.terminal?/1)

          if terminal_count == 1 do
            response = result_response(id, %{"turn" => turn_payload(turn_id, "running")})
            notifications = Enum.map(events, &event_to_notification(&1, session.id, turn_id))
            {%{state | next_turn: state.next_turn + 1}, [response | notifications]}
          else
            {state,
             [error_response(id, :invalid_turn_stream, "expected exactly one terminal event")]}
          end

        {:error, reason} ->
          {state, [error_response(id, :turn_start_failed, inspect(reason))]}
      end
    else
      nil ->
        {state, [error_response(id, :unknown_thread, "thread not found: #{inspect(thread_id)}")]}
    end
  end

  def handle_message(%__MODULE__{} = state, %{"id" => id, "method" => method}) do
    {state, [error_response(id, :method_not_found, "unsupported method: #{method}")]}
  end

  def handle_message(%__MODULE__{} = state, _message) do
    {state, [error_response(nil, :invalid_request, "expected JSON-RPC object with method")]}
  end

  defp handle_turn_start_stream(%__MODULE__{} = state, id, message) do
    params = Map.get(message, "params", %{})
    thread_id = Map.get(params, "threadId")
    input = Map.get(params, "input", [])

    with %Session{} = session <- Map.get(state.sessions, thread_id) do
      turn_id = "sari-turn-#{state.next_turn}"

      case Runtime.stream_turn(
             state.backend,
             session,
             input,
             Keyword.put(state.backend_opts, :turn_id, turn_id)
           ) do
        {:ok, stream} ->
          response = result_response(id, %{"turn" => turn_payload(turn_id, "running")})

          notifications =
            Stream.map(
              stream,
              &(&1 |> event_to_notification(session.id, turn_id) |> Json.encode!())
            )

          {%{state | next_turn: state.next_turn + 1},
           Stream.concat([Json.encode!(response)], notifications)}

        {:error, reason} ->
          {state, [Json.encode!(error_response(id, :turn_start_failed, inspect(reason)))]}
      end
    else
      nil ->
        {state,
         [
           Json.encode!(
             error_response(id, :unknown_thread, "thread not found: #{inspect(thread_id)}")
           )
         ]}
    end
  end

  defp encode_outputs({state, outputs}) do
    {state, Enum.map(outputs, &Json.encode!/1)}
  end

  defp result_response(id, result) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => result
    }
  end

  defp error_response(id, code, reason) do
    normalized = RuntimeError.normalize(reason, category: code)

    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{
        "code" => Atom.to_string(code),
        "message" => normalized.message,
        "data" => RuntimeError.to_payload(normalized)
      }
    }
  end

  defp encode_capabilities(%RuntimeCapabilities{} = capabilities) do
    %{
      "backend" => capabilities.backend,
      "name" => capabilities.name,
      "version" => capabilities.version,
      "transport" => capabilities.transport,
      "supports" => capabilities.supports,
      "unsupported" => capabilities.unsupported,
      "metadata" => capabilities.metadata
    }
  end

  defp event_to_notification(%RuntimeEvent{type: :turn_started} = event, thread_id, turn_id) do
    %{
      "method" => "turn/started",
      "params" => %{
        "threadId" => thread_id,
        "turn" => turn_payload(turn_id, "running"),
        "payload" => event.payload
      }
    }
  end

  defp event_to_notification(%RuntimeEvent{type: :assistant_delta} = event, thread_id, turn_id) do
    %{
      "method" => "item/agentMessage/delta",
      "params" => %{
        "threadId" => thread_id,
        "turnId" => turn_id,
        "itemId" => Map.get(event.metadata, :item_id, "assistant-message"),
        "delta" => Map.get(event.payload, :text) || Map.get(event.payload, "text") || ""
      }
    }
  end

  defp event_to_notification(%RuntimeEvent{type: :token_usage} = event, thread_id, _turn_id) do
    %{
      "method" => "thread/tokenUsage/updated",
      "usage" => event.payload,
      "params" => %{
        "threadId" => thread_id,
        "usage" => event.payload
      }
    }
  end

  defp event_to_notification(%RuntimeEvent{type: :turn_completed} = event, thread_id, turn_id) do
    %{
      "method" => "turn/completed",
      "params" => %{
        "threadId" => thread_id,
        "turn" => turn_payload(turn_id, "completed"),
        "result" => event.payload
      }
    }
  end

  defp event_to_notification(%RuntimeEvent{type: :turn_failed} = event, thread_id, turn_id) do
    %{
      "method" => "turn/failed",
      "params" => %{
        "threadId" => thread_id,
        "turn" => turn_payload(turn_id, "failed"),
        "error" => event.payload
      }
    }
  end

  defp event_to_notification(%RuntimeEvent{type: :turn_cancelled} = event, thread_id, turn_id) do
    %{
      "method" => "turn/cancelled",
      "params" => %{
        "threadId" => thread_id,
        "turn" => turn_payload(turn_id, "cancelled"),
        "payload" => event.payload
      }
    }
  end

  defp event_to_notification(%RuntimeEvent{type: :tool_started} = event, thread_id, turn_id) do
    %{
      "method" => "item/started",
      "params" => %{
        "threadId" => thread_id,
        "turnId" => turn_id,
        "item" => %{
          "id" => Map.get(event.payload, :id) || Map.get(event.payload, "id"),
          "type" => "tool_call",
          "name" => Map.get(event.payload, :name) || Map.get(event.payload, "name"),
          "arguments" =>
            Map.get(event.payload, :arguments) || Map.get(event.payload, "arguments") || %{}
        }
      }
    }
  end

  defp event_to_notification(%RuntimeEvent{type: :tool_output} = event, thread_id, turn_id) do
    item_id =
      Map.get(event.payload, :tool_call_id) || Map.get(event.payload, "tool_call_id") ||
        Map.get(event.payload, :id) || Map.get(event.payload, "id")

    %{
      "method" => "item/commandExecution/outputDelta",
      "params" => %{
        "threadId" => thread_id,
        "turnId" => turn_id,
        "itemId" => item_id,
        "delta" => Map.get(event.payload, :output) || Map.get(event.payload, "output") || ""
      }
    }
  end

  defp event_to_notification(%RuntimeEvent{type: :approval_requested} = event, thread_id, turn_id) do
    %{
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "threadId" => thread_id,
        "turnId" => turn_id,
        "itemId" => Map.get(event.payload, :id) || Map.get(event.payload, "id"),
        "reason" => Map.get(event.payload, :reason) || Map.get(event.payload, "reason"),
        "toolCallId" =>
          Map.get(event.payload, :tool_call_id) || Map.get(event.payload, "tool_call_id")
      }
    }
  end

  defp event_to_notification(%RuntimeEvent{} = event, thread_id, turn_id) do
    %{
      "method" => "sari/event",
      "params" => %{
        "threadId" => thread_id,
        "turnId" => turn_id,
        "type" => event.type,
        "payload" => event.payload,
        "metadata" => event.metadata
      }
    }
  end

  defp turn_payload(turn_id, status) do
    %{
      "id" => turn_id,
      "status" => status,
      "items" => []
    }
  end

  defp backend_name(backend) do
    backend
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end
end
