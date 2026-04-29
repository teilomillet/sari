defmodule Sari.RuntimeEvent do
  @moduledoc """
  Normalized event emitted by Sari runtime adapters.
  """

  @type event_type ::
          :turn_started
          | :assistant_delta
          | :reasoning_delta
          | :plan_update
          | :tool_started
          | :tool_output
          | :file_change
          | :command_started
          | :command_output
          | :approval_requested
          | :token_usage
          | :turn_completed
          | :turn_failed
          | :turn_cancelled
          | :unsupported
          | :error

  @terminal_types [:turn_completed, :turn_failed, :turn_cancelled]

  @type t :: %__MODULE__{
          type: event_type(),
          session_id: String.t() | nil,
          turn_id: String.t() | nil,
          payload: map(),
          metadata: map(),
          raw: term(),
          at: DateTime.t()
        }

  defstruct [:type, :session_id, :turn_id, payload: %{}, metadata: %{}, raw: nil, at: nil]

  @spec terminal_types() :: [event_type()]
  def terminal_types, do: @terminal_types

  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{type: type}), do: type in @terminal_types

  @spec new(event_type(), map(), keyword()) :: t()
  def new(type, payload \\ %{}, opts \\ []) when is_atom(type) and is_map(payload) do
    %__MODULE__{
      type: type,
      session_id: Keyword.get(opts, :session_id),
      turn_id: Keyword.get(opts, :turn_id),
      payload: payload,
      metadata: Keyword.get(opts, :metadata, %{}),
      raw: Keyword.get(opts, :raw),
      at: Keyword.get(opts, :at, DateTime.utc_now())
    }
  end
end
