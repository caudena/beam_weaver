defmodule BeamWeaver.Tokenizer.Approximate do
  @moduledoc """
  Lightweight tokenizer adapter for tests and local token-budget splitting.

  It is intentionally explicit and approximate. Production tokenizers should
  implement `BeamWeaver.Tokenizer` behind the same contract.
  """

  @behaviour BeamWeaver.Tokenizer

  defstruct mode: :words

  @impl true
  def encode(%__MODULE__{} = tokenizer, text, opts) when is_binary(text) do
    with {:ok, tokens} <- split_tokens(tokenizer, text, opts) do
      {:ok, Enum.map(tokens, &:erlang.phash2(&1, 1_000_000))}
    end
  end

  @impl true
  def decode(%__MODULE__{}, ids, _opts) when is_list(ids) do
    {:ok, Enum.map_join(ids, " ", &to_string/1)}
  end

  @impl true
  def count_tokens(%__MODULE__{} = tokenizer, text, opts) when is_binary(text) do
    with {:ok, tokens} <- split_tokens(tokenizer, text, opts) do
      {:ok, length(tokens)}
    end
  end

  @impl true
  def split_tokens(%__MODULE__{mode: :characters}, text, _opts) when is_binary(text),
    do: {:ok, String.graphemes(text)}

  def split_tokens(%__MODULE__{mode: :words}, text, _opts) when is_binary(text) do
    tokens =
      Regex.scan(~r/\S+\s*/u, text)
      |> Enum.map(fn [token] -> token end)

    {:ok, tokens}
  end

  def split_tokens(%__MODULE__{}, text, _opts) when is_binary(text),
    do: {:ok, Regex.scan(~r/\S+\s*/u, text) |> Enum.map(fn [token] -> token end)}
end
