defmodule Sari.PromptBudget do
  @moduledoc """
  Conservative prompt-size guard used before sending input to a backend.

  The estimate is intentionally simple and local: roughly one token per four
  UTF-8 bytes for text, plus structural overhead for maps/lists. It is not a
  tokenizer replacement; it is a fail-fast guard for obviously oversized turns
  when a backend or deployment exposes a known context limit.
  """

  alias Sari.{RuntimeCapabilities, RuntimeError}

  @bytes_per_token 4

  @spec guard(term(), RuntimeCapabilities.t(), keyword()) :: :ok | {:error, RuntimeError.t()}
  def guard(input, %RuntimeCapabilities{} = capabilities, opts \\ []) do
    case context_limit_tokens(capabilities, opts) do
      nil ->
        :ok

      limit when is_integer(limit) and limit > 0 ->
        estimated = estimate_input_tokens(input)
        reserved = non_negative_integer(Keyword.get(opts, :reserved_output_tokens), 0)
        total = estimated + reserved

        if total <= limit do
          :ok
        else
          {:error,
           RuntimeError.new(:context_limit_exceeded,
             backend: capabilities.backend,
             stage: :input_budget,
             message:
               "estimated input tokens exceed configured context limit " <>
                 "(#{total} > #{limit})",
             details: %{
               estimated_tokens: estimated,
               reserved_output_tokens: reserved,
               total_tokens: total,
               limit_tokens: limit
             },
             source:
               {:context_limit_exceeded,
                %{
                  estimated_tokens: estimated,
                  reserved_output_tokens: reserved,
                  total_tokens: total,
                  limit_tokens: limit
                }}
           )}
        end
    end
  end

  @spec estimate_input_tokens(term()) :: non_neg_integer()
  def estimate_input_tokens(input) when is_binary(input) do
    input
    |> byte_size()
    |> div_ceil(@bytes_per_token)
    |> max(1)
  end

  def estimate_input_tokens(input) when is_list(input) do
    Enum.reduce(input, 0, fn item, acc -> acc + estimate_input_tokens(item) end)
  end

  def estimate_input_tokens(input) when is_map(input) do
    text = Map.get(input, :text) || Map.get(input, "text")

    if is_binary(text) do
      estimate_input_tokens(text)
    else
      input
      |> Map.values()
      |> Enum.reduce(map_size(input), fn value, acc -> acc + estimate_input_tokens(value) end)
    end
  end

  def estimate_input_tokens(nil), do: 0
  def estimate_input_tokens(value) when is_boolean(value), do: 1
  def estimate_input_tokens(value) when is_number(value), do: 1
  def estimate_input_tokens(value), do: value |> inspect() |> estimate_input_tokens()

  @spec context_limit_tokens(RuntimeCapabilities.t(), keyword()) :: pos_integer() | nil
  def context_limit_tokens(%RuntimeCapabilities{metadata: metadata}, opts) do
    value =
      Keyword.get(opts, :context_limit_tokens) ||
        Keyword.get(opts, :context_limit) ||
        map_get(metadata, :context_limit_tokens, "context_limit_tokens") ||
        map_get(metadata, :context_limit, "context_limit")

    positive_integer(value)
  end

  defp map_get(map, atom_key, string_key) when is_map(map) do
    Map.get(map, atom_key) || Map.get(map, string_key)
  end

  defp positive_integer(value), do: non_negative_integer(value, nil)

  defp non_negative_integer(value, _fallback) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer(value, fallback) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer >= 0 -> integer
      _ -> fallback
    end
  end

  defp non_negative_integer(_value, fallback), do: fallback

  defp div_ceil(value, divisor), do: div(value + divisor - 1, divisor)
end
