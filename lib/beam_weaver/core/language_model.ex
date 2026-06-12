defmodule BeamWeaver.Core.LanguageModel do
  @moduledoc """
  Common model helpers shared by chat, LLM, and embedding providers.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.MessageLike
  alias BeamWeaver.Prompt
  alias BeamWeaver.Tokenizer

  @callback model_id(term()) :: String.t() | nil
  @callback profile(term()) :: term() | nil
  @callback count_tokens(term(), term(), keyword()) ::
              {:ok, non_neg_integer()} | {:error, Error.t()}
  @optional_callbacks model_id: 1, profile: 1, count_tokens: 3

  @doc """
  Normalizes chat model input into a message list.
  """
  @spec normalize_chat_input(term()) :: {:ok, [Message.t()]} | {:error, Error.t()}
  def normalize_chat_input(%Prompt.Value{} = value), do: {:ok, Prompt.to_messages(value)}

  def normalize_chat_input(messages) when is_list(messages) do
    if Enum.all?(messages, &match?(%Message{}, &1)) do
      {:ok, messages}
    else
      {:error, Error.new(:invalid_message, "chat message lists must contain BeamWeaver messages")}
    end
  end

  def normalize_chat_input(input) do
    with {:ok, message} <- MessageLike.to_message(input) do
      {:ok, [message]}
    end
  end

  @doc """
  Counts text approximately. This is intentionally cheap and deterministic.
  """
  @spec count_tokens_approximately(term()) :: non_neg_integer()
  def count_tokens_approximately(value) when is_binary(value) do
    value
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end

  def count_tokens_approximately(%Message{} = message),
    do: count_tokens_approximately(Message.text(message))

  def count_tokens_approximately(messages) when is_list(messages) do
    Enum.reduce(messages, 0, &(&2 + count_tokens_approximately(&1)))
  end

  def count_tokens_approximately(_value), do: 0

  @doc """
  Counts tokens through an explicit function, MFA, model callback, or approximate fallback.
  """
  @spec count_tokens(term(), term(), keyword()) :: {:ok, non_neg_integer()} | {:error, Error.t()}
  def count_tokens(counter, input, opts \\ [])
  def count_tokens(:approximate, input, _opts), do: {:ok, count_tokens_approximately(input)}

  def count_tokens({:tokenizer, tokenizer}, input, opts) do
    count_with_tokenizer(tokenizer, input, opts)
  end

  def count_tokens({:model, model}, input, opts), do: count_tokens(model, input, opts)

  def count_tokens(fun, input, _opts) when is_function(fun, 1), do: {:ok, fun.(input)}

  def count_tokens({module, function, extra_args}, input, _opts) when is_list(extra_args) do
    {:ok, apply(module, function, [input | extra_args])}
  end

  def count_tokens(model, input, opts) do
    module = model.__struct__

    if function_exported?(module, :count_tokens, 3) do
      module.count_tokens(model, input, opts)
    else
      {:error, Error.new(:unsupported_token_counter, "token counter is not supported")}
    end
  end

  defp count_with_tokenizer(tokenizer, input, opts) when is_binary(input),
    do: Tokenizer.count_tokens(tokenizer, input, opts)

  defp count_with_tokenizer(tokenizer, %Message{} = message, opts),
    do: Tokenizer.count_tokens(tokenizer, Message.text(message), opts)

  defp count_with_tokenizer(tokenizer, values, opts) when is_list(values) do
    Enum.reduce_while(values, {:ok, 0}, fn value, {:ok, acc} ->
      case count_with_tokenizer(tokenizer, value, opts) do
        {:ok, count} -> {:cont, {:ok, acc + count}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp count_with_tokenizer(tokenizer, input, opts),
    do: Tokenizer.count_tokens(tokenizer, to_string(input), opts)
end
