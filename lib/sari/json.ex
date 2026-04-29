defmodule Sari.Json do
  @moduledoc """
  Small wrapper around OTP's native JSON support.

  Keeping JSON local avoids adding dependencies for the protocol scaffold.
  """

  @spec decode(String.t()) :: {:ok, term()} | {:error, term()}
  def decode(line) when is_binary(line) do
    {:ok, line |> :json.decode() |> denormalize()}
  rescue
    error -> {:error, error}
  end

  @spec encode!(term()) :: String.t()
  def encode!(value) do
    value
    |> normalize()
    |> :json.encode()
    |> IO.iodata_to_binary()
  end

  defp normalize(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp normalize(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> normalize()
  end

  defp normalize(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {normalize_key(key), normalize(value)} end)
  end

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> normalize()
  defp normalize(true), do: true
  defp normalize(false), do: false
  defp normalize(nil), do: :null
  defp normalize(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp normalize(value), do: value

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key), do: to_string(key)

  defp denormalize(:null), do: nil

  defp denormalize(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, denormalize(value)} end)
  end

  defp denormalize(list) when is_list(list), do: Enum.map(list, &denormalize/1)
  defp denormalize(value), do: value
end
