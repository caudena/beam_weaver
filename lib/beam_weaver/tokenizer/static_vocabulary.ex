defmodule BeamWeaver.Tokenizer.StaticVocabulary do
  @moduledoc """
  Deterministic tokenizer adapter for conformance tests and examples.

  This is not an OpenAI tokenizer. It gives stable token IDs from an explicit
  vocabulary and falls back to configured unknown IDs when allowed.
  """

  @behaviour BeamWeaver.Tokenizer

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Result

  defstruct vocabulary: %{}, unknown_token: nil, split: :whitespace

  @impl true
  def encode(%__MODULE__{} = tokenizer, text, _opts) when is_binary(text) do
    tokenizer
    |> split_text(text)
    |> Result.traverse(&token_id(tokenizer, &1))
  end

  @impl true
  def decode(%__MODULE__{} = tokenizer, ids, _opts) when is_list(ids) do
    reverse = Map.new(tokenizer.vocabulary, fn {token, id} -> {id, token} end)
    {:ok, Enum.map_join(ids, &Map.get(reverse, &1, to_string(&1)))}
  end

  @impl true
  def count_tokens(%__MODULE__{} = tokenizer, text, opts) when is_binary(text) do
    with {:ok, ids} <- encode(tokenizer, text, opts) do
      {:ok, length(ids)}
    end
  end

  @impl true
  def split_tokens(%__MODULE__{} = tokenizer, text, _opts) when is_binary(text) do
    {:ok, split_text(tokenizer, text)}
  end

  defp split_text(%__MODULE__{split: %Regex{} = split}, text) do
    split
    |> Regex.scan(text)
    |> Enum.map(fn [token | _captures] -> token end)
  end

  defp split_text(%__MODULE__{split: :whitespace} = tokenizer, text),
    do: split_text(%{tokenizer | split: ~r/\S+\s*/u}, text)

  defp split_text(%__MODULE__{split: split}, text) when is_function(split, 1), do: split.(text)

  defp token_id(%__MODULE__{} = tokenizer, token) do
    cond do
      Map.has_key?(tokenizer.vocabulary, token) ->
        {:ok, Map.fetch!(tokenizer.vocabulary, token)}

      is_integer(tokenizer.unknown_token) ->
        {:ok, tokenizer.unknown_token}

      true ->
        {:error, Error.new(:unknown_token, "static vocabulary has no token ID", %{token: token})}
    end
  end
end
