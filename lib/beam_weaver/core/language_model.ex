defmodule BeamWeaver.Core.LanguageModel do
  @moduledoc """
  Helpers shared by chat models: chat input normalization and token counting.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.TokenCounter
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
  def normalize_chat_input(messages) when is_list(messages) do
    if Enum.all?(messages, &match?(%Message{}, &1)) do
      {:ok, messages}
    else
      {:error, Error.new(:invalid_message, "chat message lists must contain BeamWeaver messages")}
    end
  end

  def normalize_chat_input(input) do
    with {:ok, message} <- Message.from(input) do
      {:ok, [message]}
    end
  end

  @doc """
  Estimates tokens cheaply and deterministically: about four characters per
  token, plus three per message for its role and framing.

  Messages are counted like
  `BeamWeaver.Core.Messages.Utils.count_tokens_approximately/2`, so a budget
  means the same everywhere the `:approximate` counter is used, such as
  `BeamWeaver.Core.Messages.Utils.trim/2`.
  """
  @spec count_tokens_approximately(term()) :: non_neg_integer()
  def count_tokens_approximately(value) when is_binary(value),
    do: ceil(String.length(value) / 4)

  def count_tokens_approximately(%Message{} = message), do: TokenCounter.count([message])

  def count_tokens_approximately(values) when is_list(values) do
    {messages, others} = Enum.split_with(values, &match?(%Message{}, &1))
    TokenCounter.count(messages) + Enum.reduce(others, 0, &(&2 + count_tokens_approximately(&1)))
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
    with {:ok, counts} <- BeamWeaver.Result.traverse(values, &count_with_tokenizer(tokenizer, &1, opts)),
         do: {:ok, Enum.sum(counts)}
  end

  defp count_with_tokenizer(tokenizer, input, opts),
    do: Tokenizer.count_tokens(tokenizer, to_string(input), opts)
end
