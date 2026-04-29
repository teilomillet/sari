defmodule Sari.Runtime do
  @moduledoc """
  Backend-neutral runtime entry points.
  """

  alias Sari.{PromptBudget, RuntimeCapabilities, RuntimeEvent, Session}

  @type backend :: module()

  @spec capabilities(backend(), keyword()) :: RuntimeCapabilities.t()
  def capabilities(backend, opts \\ []) when is_atom(backend) do
    backend.capabilities(opts)
  end

  @spec start_session(backend(), map(), keyword()) :: {:ok, Session.t()} | {:error, term()}
  def start_session(backend, params, opts \\ []) when is_atom(backend) and is_map(params) do
    with :ok <- ensure_backend!(backend),
         %RuntimeCapabilities{} = capabilities <- backend.capabilities(opts),
         :ok <- RuntimeCapabilities.validate_required(capabilities) do
      backend.start_session(params, opts)
    end
  end

  @spec resume_session(backend(), String.t(), keyword()) :: {:ok, Session.t()} | {:error, term()}
  def resume_session(backend, session_id, opts \\ [])
      when is_atom(backend) and is_binary(session_id) do
    with :ok <- ensure_backend!(backend),
         %RuntimeCapabilities{} = capabilities <- backend.capabilities(opts),
         :ok <- RuntimeCapabilities.validate_required(capabilities),
         true <-
           RuntimeCapabilities.supports?(capabilities, :resume) ||
             {:error, {:unsupported, :resume}} do
      backend.resume_session(session_id, opts)
    end
  end

  @spec stream_turn(backend(), Session.t(), term(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def stream_turn(backend, %Session{} = session, input, opts \\ []) when is_atom(backend) do
    with :ok <- ensure_backend!(backend),
         %RuntimeCapabilities{} = capabilities <- backend.capabilities(opts),
         :ok <- RuntimeCapabilities.validate_required(capabilities),
         :ok <- PromptBudget.guard(input, capabilities, opts),
         {:ok, stream} <- backend.start_turn(session, input, opts) do
      {:ok, Stream.map(stream, &normalize_event!(&1, session))}
    end
  end

  @spec collect_turn(backend(), Session.t(), term(), keyword()) ::
          {:ok, %{events: [RuntimeEvent.t()], terminal: RuntimeEvent.t()}} | {:error, term()}
  def collect_turn(backend, %Session{} = session, input, opts \\ []) when is_atom(backend) do
    with {:ok, stream} <- stream_turn(backend, session, input, opts) do
      events = Enum.to_list(stream)

      case Enum.filter(events, &RuntimeEvent.terminal?/1) do
        [terminal] -> {:ok, %{events: events, terminal: terminal}}
        [] -> {:error, {:missing_terminal_event, events}}
        terminals -> {:error, {:multiple_terminal_events, terminals}}
      end
    end
  end

  @spec interrupt(backend(), Session.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def interrupt(backend, %Session{} = session, turn_id, opts \\ [])
      when is_atom(backend) and is_binary(turn_id) do
    backend.interrupt(session, turn_id, opts)
  end

  defp normalize_event!(%RuntimeEvent{} = event, %Session{} = session) do
    %RuntimeEvent{event | session_id: event.session_id || session.id}
  end

  defp normalize_event!(%{type: type, payload: payload} = event, %Session{} = session)
       when is_atom(type) and is_map(payload) do
    RuntimeEvent.new(type, payload,
      session_id: Map.get(event, :session_id, session.id),
      turn_id: Map.get(event, :turn_id),
      metadata: Map.get(event, :metadata, %{}),
      raw: Map.get(event, :raw)
    )
  end

  defp normalize_event!(other, _session) do
    raise ArgumentError, "backend emitted invalid runtime event: #{inspect(other)}"
  end

  defp ensure_backend!(backend) do
    required = [:capabilities, :start_session, :resume_session, :start_turn, :interrupt]

    case Code.ensure_loaded(backend) do
      {:module, ^backend} ->
        missing =
          required
          |> Enum.reject(&function_exported?(backend, &1, callback_arity(&1)))

        case missing do
          [] -> :ok
          _ -> {:error, {:invalid_backend, backend, missing}}
        end

      {:error, reason} ->
        {:error, {:backend_not_loaded, backend, reason}}
    end
  end

  defp callback_arity(:capabilities), do: 1
  defp callback_arity(:start_session), do: 2
  defp callback_arity(:resume_session), do: 2
  defp callback_arity(:start_turn), do: 3
  defp callback_arity(:interrupt), do: 3
end
