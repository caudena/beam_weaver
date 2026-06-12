defmodule BeamWeaver.Tokenizer.OpenAI do
  @moduledoc """
  Exact OpenAI tokenizer adapter backed by `FastestTiktoken`.

  The adapter is explicit: callers pass a struct directly or resolve one from
  model profile metadata. BeamWeaver does not use a global tokenizer registry.
  """

  @behaviour BeamWeaver.Tokenizer

  alias BeamWeaver.Core.Error

  defstruct model: nil, encoding: nil, allowed_special: []

  @type t :: %__MODULE__{
          model: String.t() | nil,
          encoding: atom() | String.t() | nil,
          allowed_special: :all | [String.t()]
        }

  @impl true
  def encode(%__MODULE__{} = tokenizer, text, opts) when is_binary(text) do
    with {:ok, selector_opts} <- selector_opts(tokenizer, opts) do
      call_fastest_tiktoken(:encode, [text, selector_opts], selector_opts)
    end
  end

  @impl true
  def decode(%__MODULE__{} = tokenizer, ids, opts) when is_list(ids) do
    with {:ok, selector_opts} <- selector_opts(tokenizer, opts) do
      call_fastest_tiktoken(:decode, [ids, selector_opts], selector_opts)
    end
  end

  @impl true
  def count_tokens(%__MODULE__{} = tokenizer, text, opts) when is_binary(text) do
    with {:ok, selector_opts} <- selector_opts(tokenizer, opts) do
      call_fastest_tiktoken(:count_tokens, [text, selector_opts], selector_opts)
    end
  end

  @impl true
  def split_tokens(%__MODULE__{} = tokenizer, text, opts) when is_binary(text) do
    with {:ok, selector_opts} <- selector_opts(tokenizer, opts) do
      call_fastest_tiktoken(:split_tokens, [text, selector_opts], selector_opts)
    end
  end

  defp selector_opts(%__MODULE__{} = tokenizer, opts) do
    model = Keyword.get(opts, :model, tokenizer.model)
    encoding = Keyword.get(opts, :encoding, tokenizer.encoding)

    selector =
      cond do
        is_binary(model) and model != "" and is_nil(encoding) ->
          [model: model]

        not is_nil(encoding) and is_nil(model) ->
          [encoding: encoding]

        is_nil(model) and is_nil(encoding) ->
          []

        true ->
          [model: model, encoding: encoding]
      end

    selector =
      Keyword.put(
        selector,
        :allowed_special,
        Keyword.get(opts, :allowed_special, tokenizer.allowed_special || [])
      )

    case selector do
      [allowed_special: _allowed_special] ->
        {:error, Error.new(:invalid_tokenizer, "OpenAI tokenizer requires a model or encoding")}

      _selector ->
        {:ok, selector}
    end
  end

  defp call_fastest_tiktoken(function, args, selector_opts) do
    case apply(FastestTiktoken, function, args) do
      {:ok, value} ->
        {:ok, value}

      {:error, reason} ->
        {:error, tokenizer_error(reason, selector_opts)}

      value ->
        {:ok, value}
    end
  rescue
    exception ->
      {:error,
       Error.new(:tokenizer_error, "OpenAI tokenizer operation raised", %{
         reason: Exception.message(exception)
       })}
  end

  defp tokenizer_error(:missing_selector, _selector_opts),
    do: Error.new(:invalid_tokenizer, "OpenAI tokenizer requires a model or encoding")

  defp tokenizer_error(:ambiguous_selector, selector_opts) do
    Error.new(:invalid_tokenizer, "OpenAI tokenizer requires either a model or encoding", %{
      model: Keyword.get(selector_opts, :model),
      encoding: Keyword.get(selector_opts, :encoding)
    })
  end

  defp tokenizer_error({:unsupported_encoding, encoding}, selector_opts) do
    Error.new(:unsupported_tokenizer, "OpenAI tokenizer encoding is not supported", %{
      encoding: Keyword.get(selector_opts, :encoding, encoding)
    })
  end

  defp tokenizer_error({:unsupported_model, model}, selector_opts) do
    Error.new(:unsupported_tokenizer, "OpenAI tokenizer model is not supported", %{
      model: Keyword.get(selector_opts, :model, model)
    })
  end

  defp tokenizer_error(reason, _selector_opts) do
    Error.new(:unsupported_tokenizer, "OpenAI tokenizer operation failed", %{
      reason: inspect(reason)
    })
  end
end
