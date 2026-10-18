defmodule BeamWeaver.Retriever do
  @moduledoc """
  The retriever contract: a struct whose module implements `retrieve/3` to
  find the documents for a query, such as the retriever
  `BeamWeaver.VectorStore.as_retriever/2` returns.

  `as_tool/2` turns a retriever into a search tool an agent can call.
  """

  alias BeamWeaver.Core.Document
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Tool

  @doc """
  Find documents for a query using the supplied request options; preserve source metadata and return errors explicitly.
  """
  @callback retrieve(term(), String.t(), keyword()) ::
              {:ok, [Document.t()]} | {:error, Error.t()}

  @doc """
  Returns {:ok, documents} or an error for a text query. Adapter exceptions normalize to :retriever_error.
  """
  def retrieve(retriever, query, opts \\ [])

  def retrieve(retriever, query, opts) when is_binary(query) do
    retriever.__struct__.retrieve(retriever, query, opts)
  rescue
    exception -> {:error, Error.new(:retriever_error, Exception.message(exception))}
  end

  def retrieve(_retriever, _query, _opts),
    do: {:error, Error.new(:invalid_retriever_query, "retriever query must be a string")}

  @doc """
  Builds a search tool with one `query` argument that returns the documents
  the retriever finds, joined into one text.

  Options: `name:` (default `"file_search"`), `description:`,
  `document_separator:` (default `"\\n\\n"`), and `document_formatter:` (a
  function from document to text) or `document_prompt:` (a template such as
  `"{source}: {content}"`, where `{content}` is the document's text, any
  other `{name}` its metadata value under that name, and `{{` and `}}` are
  literal braces) to format each document. With
  `response_format: :content_and_artifact`, the documents also travel as the
  result's artifact, which an agent keeps in the tool message's
  `metadata.artifact`.
  """
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
          content = Enum.map_join(docs, separator, &format_document(&1, formatter, prompt))

          if response_format in [:content_and_artifact, "content_and_artifact"] do
            {:ok, {content, docs}}
          else
            {:ok, content}
          end
        end
      end
    )
  end

  defp format_document(document, formatter, _prompt) when is_function(formatter, 1),
    do: formatter.(document)

  defp format_document(document, _formatter, nil) do
    case document do
      %Document{content: content} -> content
      other -> to_string(other)
    end
  end

  defp format_document(%Document{} = document, _formatter, prompt) when is_binary(prompt) do
    Regex.replace(~r/\{\{|\}\}|\{(\w+)\}/, prompt, fn
      "{{", _name -> "{"
      "}}", _name -> "}"
      _placeholder, name -> to_string(placeholder_value(document, name))
    end)
  end

  defp placeholder_value(%Document{content: content}, "content"), do: content

  # A missing value raises, which the tool reports as its error.
  defp placeholder_value(%Document{metadata: metadata}, name) do
    case Enum.find(metadata, fn {key, _value} -> to_string(key) == name end) do
      {_key, value} -> value
      nil -> raise ArgumentError, "document_prompt uses {#{name}}, but the document has no #{name} metadata"
    end
  end
end
