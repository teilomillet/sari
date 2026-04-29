defmodule Sari.RuntimeConformance do
  @moduledoc """
  Deterministic conformance checks for Sari runtime backends.

  These checks are intentionally local and cheap. Real backend smoke tests still
  prove transport/auth/model behavior, while this module proves that every
  adapter declares the same runtime surface and emits normalized turn events.
  """

  alias Sari.{RuntimeCapabilities, RuntimeEvent, Session}

  @callbacks [
    capabilities: 1,
    start_session: 2,
    resume_session: 2,
    start_turn: 3,
    interrupt: 3
  ]

  @spec verify_backend(module(), keyword()) :: :ok | {:error, [term()]}
  def verify_backend(backend, opts \\ []) when is_atom(backend) do
    failures =
      []
      |> require_loaded(backend)
      |> require_callbacks(backend)
      |> require_capabilities(backend, opts)
      |> Enum.reverse()

    case failures do
      [] -> :ok
      _ -> {:error, failures}
    end
  end

  @spec verify_turn_events([RuntimeEvent.t()], Session.t(), String.t()) ::
          :ok | {:error, [term()]}
  def verify_turn_events(events, %Session{} = session, turn_id)
      when is_list(events) and is_binary(turn_id) do
    failures =
      []
      |> require_runtime_events(events)
      |> require_session_ids(events, session.id)
      |> require_turn_ids(events, turn_id)
      |> require_started_event(events)
      |> require_single_terminal_event(events)
      |> require_no_events_after_terminal(events)
      |> Enum.reverse()

    case failures do
      [] -> :ok
      _ -> {:error, failures}
    end
  end

  defp require_loaded(failures, backend) do
    case Code.ensure_loaded(backend) do
      {:module, ^backend} -> failures
      {:error, reason} -> [{:backend_not_loaded, backend, reason} | failures]
    end
  end

  defp require_callbacks(failures, backend) do
    Enum.reduce(@callbacks, failures, fn {callback, arity}, failures ->
      if function_exported?(backend, callback, arity) do
        failures
      else
        [{:missing_callback, callback, arity} | failures]
      end
    end)
  end

  defp require_capabilities(failures, backend, opts) do
    case safe_capabilities(backend, opts) do
      %RuntimeCapabilities{} = capabilities ->
        failures
        |> require_capability_identity(capabilities)
        |> require_required_capabilities(capabilities)
        |> require_complete_support_map(capabilities)
        |> require_known_support_keys(capabilities)
        |> require_unsupported_reasons(capabilities)

      other ->
        [{:invalid_capabilities, other} | failures]
    end
  end

  defp safe_capabilities(backend, opts) do
    backend.capabilities(opts)
  rescue
    error -> {:raised, error}
  end

  defp require_capability_identity(failures, %RuntimeCapabilities{} = capabilities) do
    failures
    |> maybe_require(capabilities.backend in [nil, ""], {:missing_capability_identity, :backend})
    |> maybe_require(capabilities.name in [nil, ""], {:missing_capability_identity, :name})
    |> maybe_require(
      capabilities.transport in [nil, ""],
      {:missing_capability_identity, :transport}
    )
  end

  defp require_required_capabilities(failures, %RuntimeCapabilities{} = capabilities) do
    case RuntimeCapabilities.validate_required(capabilities) do
      :ok -> failures
      {:error, reason} -> [{:missing_required_capabilities, reason} | failures]
    end
  end

  defp require_complete_support_map(failures, %RuntimeCapabilities{supports: supports}) do
    missing = RuntimeCapabilities.all_capabilities() -- Map.keys(supports)

    case missing do
      [] -> failures
      _ -> [{:missing_support_declarations, missing} | failures]
    end
  end

  defp require_known_support_keys(failures, %RuntimeCapabilities{supports: supports}) do
    unknown = Map.keys(supports) -- RuntimeCapabilities.all_capabilities()

    case unknown do
      [] -> failures
      _ -> [{:unknown_support_declarations, unknown} | failures]
    end
  end

  defp require_unsupported_reasons(failures, %RuntimeCapabilities{} = capabilities) do
    Enum.reduce(capabilities.supports, failures, fn
      {_capability, true}, failures ->
        failures

      {capability, value}, failures when value in [false, :degraded] ->
        if Map.has_key?(capabilities.unsupported, capability) do
          failures
        else
          [{:missing_unsupported_reason, capability, value} | failures]
        end

      {capability, value}, failures ->
        [{:invalid_support_value, capability, value} | failures]
    end)
  end

  defp require_runtime_events(failures, events) do
    invalid = Enum.reject(events, &match?(%RuntimeEvent{}, &1))

    case invalid do
      [] -> failures
      _ -> [{:invalid_runtime_events, invalid} | failures]
    end
  end

  defp require_session_ids(failures, events, session_id) do
    invalid =
      Enum.reject(events, fn
        %RuntimeEvent{session_id: ^session_id} -> true
        _ -> false
      end)

    case invalid do
      [] -> failures
      _ -> [{:invalid_session_ids, session_id} | failures]
    end
  end

  defp require_turn_ids(failures, events, turn_id) do
    invalid =
      Enum.reject(events, fn
        %RuntimeEvent{turn_id: ^turn_id} -> true
        _ -> false
      end)

    case invalid do
      [] -> failures
      _ -> [{:invalid_turn_ids, turn_id} | failures]
    end
  end

  defp require_started_event(failures, events) do
    case Enum.count(events, &(&1.type == :turn_started)) do
      1 -> failures
      count -> [{:invalid_turn_started_count, count} | failures]
    end
  end

  defp require_single_terminal_event(failures, events) do
    case Enum.count(events, &RuntimeEvent.terminal?/1) do
      1 -> failures
      count -> [{:invalid_terminal_event_count, count} | failures]
    end
  end

  defp require_no_events_after_terminal(failures, events) do
    terminal_index = Enum.find_index(events, &RuntimeEvent.terminal?/1)

    cond do
      terminal_index == nil ->
        failures

      terminal_index == length(events) - 1 ->
        failures

      true ->
        [{:events_after_terminal, length(events) - terminal_index - 1} | failures]
    end
  end

  defp maybe_require(failures, true, failure), do: [failure | failures]
  defp maybe_require(failures, false, _failure), do: failures
end
