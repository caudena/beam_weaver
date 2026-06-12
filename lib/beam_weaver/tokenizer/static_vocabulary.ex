defmodule BeamWeaver.Tokenizer.StaticVocabulary do
  @moduledoc """
  Deterministic tokenizer adapter for conformance tests and examples.

  This is not an OpenAI tokenizer. It gives stable token IDs from an explicit
  vocabulary and falls back to configured unknown IDs when allowed.
  """

  @behaviour BeamWeaver.Tokenizer

  alias BeamWeaver.Core.Error

  defstruct vocabulary: %{}, unknown_token: nil, split: :whitespace

  @impl true
  def encode(%__MODULE__{} = tokenizer, text, _opts) when is_binary(text) do
    tokenizer
    |> split_text(text)
    |> Enum.reduce_while({:ok, []}, fn token, {:ok, ids} ->
      case token_id(tokenizer, token) do
        {:ok, id} -> {:cont, {:ok, [id | ids]}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      error -> error
    end
  end

  @impl true
  def decode(%__MODULE__{} = tokenizer, ids, _opts) when is_list(ids) do
    reverse =
      Map.new(tokenizer.vocabulary, fn {token, id} -> {id, token} end)

    tokens =
      Enum.map(ids, fn id ->
        Map.get(reverse, id, to_string(id))
      end)

    {:ok, Enum.join(tokens)}
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

  defp split_text(%__MODULE__{split: :whitespace}, text) do
    ~r/\S+\s*/u
    |> Regex.scan(text)
    |> Enum.map(fn [token | _captures] -> token end)
  end

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
