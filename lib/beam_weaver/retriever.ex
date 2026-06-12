defmodule BeamWeaver.Retriever do
  @moduledoc """
  Runnable-compatible retriever contract.
  """

  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.Document
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Prompt
  alias BeamWeaver.Runnable

  @callback retrieve(term(), String.t(), keyword()) ::
              {:ok, [Document.t()]} | {:error, Error.t()}

  def retrieve(retriever, query, opts \\ [])

  def retrieve(retriever, query, opts) when is_binary(query) do
    retriever.__struct__.retrieve(retriever, query, opts)
  rescue
    exception -> {:error, Error.new(:retriever_error, Exception.message(exception))}
  end

  def retrieve(_retriever, _query, _opts),
    do: {:error, Error.new(:invalid_retriever_query, "retriever query must be a string")}

  def async_retrieve(retriever, query, opts \\ []) do
    Async.run_call(opts, &retrieve(retriever, query, &1))
  end

  def as_runnable(retriever), do: struct(BeamWeaver.Retriever.Runnable, retriever: retriever)

  def as_tool(retriever, opts \\ []) do
    response_format = Keyword.get(opts, :response_format)
    separator = Keyword.get(opts, :document_separator, "\n\n")
    formatter = Keyword.get(opts, :document_formatter)
    prompt = Keyword.get(opts, :document_prompt)

    Tool.from_function!(
      name: Keyword.get(opts, :name, "file_search"),
      description: Keyword.get(opts, :description, "Search documents."),
      input_schema: %{
        "type" => "object",
        "properties" => %{"query" => %{"type" => "string"}},
        "required" => ["query"]
      },
      response_format: response_format,
      handler: fn %{"query" => query}, call_opts ->
        with {:ok, docs} <- retrieve(retriever, query, call_opts) do
          content = format_documents(docs, separator, formatter, prompt)

          if response_format in [:content_and_artifact, "content_and_artifact"] do
            {:ok, {content, docs}}
          else
            {:ok, content}
          end
        end
      end
    )
  end

  defp format_documents(documents, separator, formatter, prompt) do
    Enum.map_join(documents, separator, &format_document(&1, formatter, prompt))
  end

  defp format_document(document, formatter, _prompt) when is_function(formatter, 1),
    do: formatter.(document)

  defp format_document(document, _formatter, nil) do
    case document do
      %Document{content: content} -> content
      other -> to_string(other)
    end
  end

  defp format_document(document, _formatter, prompt) do
    case Prompt.format_document(document, prompt) do
      {:ok, text} -> text
      {:error, error} -> raise RuntimeError, message: error.message
    end
  end

  defmodule Runnable do
    @moduledoc false
    @behaviour BeamWeaver.Runnable

    defstruct [:retriever]

    def invoke(%__MODULE__{retriever: retriever}, query, opts) do
      BeamWeaver.Retriever.retrieve(retriever, query, opts)
    end
  end
end
