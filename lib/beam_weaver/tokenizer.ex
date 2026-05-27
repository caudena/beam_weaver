defmodule BeamWeaver.Tokenizer do
  @moduledoc """
  Explicit tokenizer contract used by text splitters and token-budget helpers.
  """

  alias BeamWeaver.Core.Error

  @callback encode(term(), String.t(), keyword()) ::
              {:ok, [non_neg_integer()]} | {:error, Error.t()}
  @callback decode(term(), [non_neg_integer()], keyword()) ::
              {:ok, String.t()} | {:error, Error.t()}
  @callback count_tokens(term(), String.t(), keyword()) ::
              {:ok, non_neg_integer()} | {:error, Error.t()}
  @callback split_tokens(term(), String.t(), keyword()) ::
              {:ok, [String.t()]} | {:error, Error.t()}

  @spec encode(term(), String.t(), keyword()) :: {:ok, [non_neg_integer()]} | {:error, Error.t()}
  def encode(tokenizer, text, opts \\ [])

  def encode(%module{} = tokenizer, text, opts) when is_binary(text),
    do: module.encode(tokenizer, text, opts)

  def encode(_tokenizer, _text, _opts),
    do: {:error, Error.new(:invalid_tokenizer, "expected a tokenizer adapter and string text")}

  @spec decode(term(), [non_neg_integer()], keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def decode(tokenizer, ids, opts \\ [])

  def decode(%module{} = tokenizer, ids, opts) when is_list(ids),
    do: module.decode(tokenizer, ids, opts)

  def decode(_tokenizer, _ids, _opts),
    do: {:error, Error.new(:invalid_tokenizer, "expected a tokenizer adapter and token ids")}

  @spec count_tokens(term(), String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  def count_tokens(tokenizer, text, opts \\ [])

  def count_tokens(%module{} = tokenizer, text, opts) when is_binary(text),
    do: module.count_tokens(tokenizer, text, opts)

  def count_tokens(_tokenizer, _text, _opts),
    do: {:error, Error.new(:invalid_tokenizer, "expected a tokenizer adapter and string text")}

  @spec split_tokens(term(), String.t(), keyword()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def split_tokens(tokenizer, text, opts \\ [])

  def split_tokens(%module{} = tokenizer, text, opts) when is_binary(text),
    do: module.split_tokens(tokenizer, text, opts)

  def split_tokens(_tokenizer, _text, _opts),
    do: {:error, Error.new(:invalid_tokenizer, "expected a tokenizer adapter and string text")}
end
