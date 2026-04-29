defmodule Sari.TokenUsage do
  @moduledoc """
  Backend-neutral token and cost accounting snapshot.
  """

  @type t :: %__MODULE__{
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          total_tokens: non_neg_integer() | nil,
          cost_usd: number() | nil,
          metadata: map()
        }

  defstruct [:input_tokens, :output_tokens, :total_tokens, :cost_usd, metadata: %{}]
end
