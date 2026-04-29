defmodule Sari.ApprovalRequest do
  @moduledoc """
  Backend-neutral approval request.
  """

  @type kind :: :command | :file_change | :tool | :permission | :input

  @type t :: %__MODULE__{
          id: String.t(),
          kind: kind(),
          title: String.t() | nil,
          payload: map(),
          metadata: map()
        }

  defstruct [:id, :kind, :title, payload: %{}, metadata: %{}]
end
