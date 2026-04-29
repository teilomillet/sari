defmodule Sari.Session do
  @moduledoc """
  Backend-neutral runtime session.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          backend: atom(),
          cwd: String.t() | nil,
          metadata: map(),
          started_at: DateTime.t() | nil
        }

  defstruct [:id, :backend, :cwd, metadata: %{}, started_at: nil]

  @spec new(String.t(), atom(), keyword()) :: t()
  def new(id, backend, opts \\ []) when is_binary(id) and is_atom(backend) do
    %__MODULE__{
      id: id,
      backend: backend,
      cwd: Keyword.get(opts, :cwd),
      metadata: Keyword.get(opts, :metadata, %{}),
      started_at: Keyword.get(opts, :started_at, DateTime.utc_now())
    }
  end
end
