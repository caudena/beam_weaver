defmodule BeamWeaver.Tools.FileSearch do
  @moduledoc """
  Retriever-backed or filesystem-backed file/document search tool.
  """

  @behaviour BeamWeaver.Core.Tool

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Retriever
  alias BeamWeaver.Tools.FileSearch.Filesystem

  defstruct [
    :retriever,
    roots: [],
    include: ["**/*"],
    exclude: [],
    include_hidden?: false,
    max_results: 10,
    max_file_bytes: 1_000_000,
    snippet_bytes: 240,
    query_mode: :literal,
    output_mode: :content,
    sort: :path,
    name: "file_search",
    description: "Search indexed files and documents."
  ]

  def new(opts \\ []) do
    %__MODULE__{
      retriever: Keyword.get(opts, :retriever),
      roots: opts |> Keyword.get(:roots, []) |> List.wrap() |> Enum.map(&Path.expand/1),
      include: opts |> Keyword.get(:include, ["**/*"]) |> List.wrap(),
      exclude: opts |> Keyword.get(:exclude, []) |> List.wrap(),
      include_hidden?: Keyword.get(opts, :include_hidden?, false),
      max_results: Keyword.get(opts, :max_results, 10),
      max_file_bytes: Keyword.get(opts, :max_file_bytes, 1_000_000),
      snippet_bytes: Keyword.get(opts, :snippet_bytes, 240),
      query_mode: Keyword.get(opts, :query_mode, :literal),
      output_mode: Keyword.get(opts, :output_mode, :content),
      sort: Keyword.get(opts, :sort, :path),
      name: Keyword.get(opts, :name, "file_search"),
      description: Keyword.get(opts, :description, "Search indexed files and documents.")
    }
    |> ensure_search_source!()
  end

  @impl true
  def name(%__MODULE__{name: name}), do: name

  @impl true
  def description(%__MODULE__{description: description}), do: description

  @impl true
  def input_schema(_tool) do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{"type" => "string"},
        "max_results" => %{"type" => "integer", "minimum" => 1},
        "query_mode" => %{"type" => "string", "enum" => ["literal", "regex"]},
        "output_mode" => %{"type" => "string", "enum" => ["content", "count"]}
      },
      "required" => ["query"]
    }
  end

  @impl true
  def injected(_tool), do: %{}

  @impl true
  def return_direct(_tool), do: false

  @impl true
  def response_format(_tool), do: nil

  @impl true
  def output_schema(_tool), do: %{"type" => "array"}

  @impl true
  def tags(_tool), do: [:retrieval, :file_search]

  @impl true
  def metadata(%__MODULE__{retriever: nil}),
    do: %{source: :filesystem}

  def metadata(_tool), do: %{source: :retriever}

  @impl true
  def provider_opts(_tool), do: %{}

  @impl true
  def invoke(%__MODULE__{} = tool, input, opts) do
    query = Map.get(input, "query") || Map.get(input, :query)

    cond do
      not valid_query?(query) ->
        {:error, Error.new(:invalid_file_search_query, "file search query must be a non-empty string")}

      tool.retriever != nil ->
        retriever_search(tool.retriever, query, opts)

      true ->
        Filesystem.search(tool, input)
    end
  end

  defp retriever_search(retriever, query, opts) do
    with {:ok, documents} <- Retriever.retrieve(retriever, query, opts) do
      {:ok, Enum.map(documents, &Map.from_struct/1)}
    end
  end

  defp valid_query?(query), do: is_binary(query) and String.trim(query) != ""

  defp ensure_search_source!(%__MODULE__{retriever: nil, roots: []}) do
    raise ArgumentError, "file search requires either :retriever or :roots"
  end

  defp ensure_search_source!(%__MODULE__{} = tool), do: tool
end
