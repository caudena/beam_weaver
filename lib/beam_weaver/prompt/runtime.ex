defmodule BeamWeaver.Prompt.Runtime do
  @moduledoc false

  import Kernel, except: [to_string: 1]

  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Document
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Models
  alias BeamWeaver.Prompt.StructuredChatTemplate
  alias BeamWeaver.Prompt.Value
  alias BeamWeaver.Result
  alias BeamWeaver.Runnable

  def structured_chain(%StructuredChatTemplate{} = prompt, model, opts \\ []) do
    {sequence_opts, model_opts} = Keyword.split(opts, [:name])

    structured_model =
      Models.with_structured_output(
        model,
        prompt.schema,
        Keyword.merge(prompt.structured_output_opts, model_opts)
      )

    model_step =
      Runnable.lambda(
        fn value, call_opts ->
          ChatModel.invoke(structured_model, Value.to_messages(value), call_opts)
        end,
        name: :structured_output_model
      )

    Runnable.sequence([prompt, model_step], name: Keyword.get(sequence_opts, :name))
  end

  def format(prompt, input, opts \\ []) do
    with {:ok, value} <- format_prompt(prompt, input, opts) do
      {:ok, Value.to_string(value)}
    end
  end

  def format_prompt(prompt, input, opts \\ []), do: Runnable.invoke(prompt, input, opts)

  @spec async_format(term(), term(), keyword()) :: Async.handle()
  def async_format(prompt, input, opts \\ []) do
    Async.run_call(opts, &format(prompt, input, &1))
  end

  @spec async_format_prompt(term(), term(), keyword()) :: Async.handle()
  def async_format_prompt(prompt, input, opts \\ []),
    do: Runnable.async_invoke(prompt, input, opts)

  def format_document(%Document{} = document, prompt) do
    input =
      Map.merge(document.metadata, %{page_content: document.content, content: document.content})

    with {:ok, value} <- Runnable.invoke(prompt, input) do
      {:ok, Value.to_string(value)}
    end
  end

  def format_document(document, prompt) when is_map(document) do
    content = Map.get(document, :content) || Map.get(document, "content") || ""
    metadata = Map.get(document, :metadata) || Map.get(document, "metadata") || %{}
    format_document(Document.new!(content, metadata: metadata), prompt)
  end

  @spec async_format_document(Document.t() | map(), term(), keyword()) :: Async.handle()
  def async_format_document(document, prompt, opts \\ []) do
    Async.run_call(opts, fn _call_opts -> format_document(document, prompt) end)
  end

  def batch(prompt, inputs, opts) when is_list(inputs) do
    Result.traverse(inputs, &Runnable.invoke(prompt, &1, opts))
  end

  def stream(prompt, input, opts) do
    case Runnable.invoke(prompt, input, opts) do
      {:ok, value} -> {:ok, [value]}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def transform(prompt, input, opts) do
    if Enumerable.impl_for(input) do
      stream =
        Stream.map(input, fn item ->
          case Runnable.invoke(prompt, item, opts) do
            {:ok, value} -> value
            {:error, %Error{} = error} -> error
          end
        end)

      {:ok, stream}
    else
      {:error, Error.new(:invalid_runnable_input, "prompt transform input must be Enumerable")}
    end
  end
end
