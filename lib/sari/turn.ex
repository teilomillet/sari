defmodule Sari.Turn do
  @moduledoc """
  Backend-neutral runtime turn.
  """

  @type status :: :running | :completed | :failed | :cancelled

  @type t :: %__MODULE__{
          id: String.t(),
          session_id: String.t(),
          status: status(),
          metadata: map(),
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil
        }

  defstruct [
    :id,
    :session_id,
    status: :running,
    metadata: %{},
    started_at: nil,
    completed_at: nil
  ]
end
