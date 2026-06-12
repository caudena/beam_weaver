defmodule BeamWeaver.Indexing.DocumentIndex.Memory do
  @moduledoc """
  ETS-backed in-memory read/write document index.
  """

  use BeamWeaver.Indexing.DocumentIndex
  @behaviour BeamWeaver.Retriever

  alias BeamWeaver.Core.Document
  alias BeamWeaver.Core.Error

  defstruct [:table, top_k: 4]

  @type t :: %__MODULE__{table: :ets.tid(), top_k: pos_integer()}

  def new(opts \\ []) do
    visibility = Keyword.get(opts, :visibility, :public)

    %__MODULE__{
      table:
        Keyword.get_lazy(opts, :table, fn ->
          :ets.new(:beam_weaver_document_index, [:set, visibility])
        end),
      top_k: Keyword.get(opts, :top_k, 4)
    }
  end

  @impl BeamWeaver.Indexing.DocumentIndex
  def upsert(%__MODULE__{} = index, documents, _opts) when is_list(documents) do
    documents
    |> Enum.reduce({[], []}, fn
      %Document{} = document, {ok, failed} ->
        id = document.id || generated_id()
        stored = %{document | id: id}
        :ets.insert(index.table, {id, stored})
        {[id | ok], failed}

      other, {ok, failed} ->
        {ok, [other | failed]}
    end)
    |> then(fn {ok, failed} ->
      {:ok, %{succeeded: Enum.reverse(ok), failed: Enum.reverse(failed)}}
    end)
  end

  @impl BeamWeaver.Indexing.DocumentIndex
  def delete(%__MODULE__{}, nil, _opts) do
    {:error, Error.new(:missing_document_ids, "document ids must be provided for deletion")}
  end

  def delete(%__MODULE__{} = index, ids, _opts) when is_list(ids) do
    succeeded =
      Enum.flat_map(ids, fn id ->
        case :ets.lookup(index.table, id) do
          [{^id, _document}] ->
            :ets.delete(index.table, id)
            [id]

          [] ->
            []
        end
      end)

    {:ok,
     %{
       succeeded: succeeded,
       failed: [],
       num_deleted: length(succeeded),
       num_failed: 0
     }}
  end

  @impl BeamWeaver.Indexing.DocumentIndex
  def get(%__MODULE__{} = index, ids, _opts) when is_list(ids) do
    documents =
      Enum.flat_map(ids, fn id ->
        case :ets.lookup(index.table, id) do
          [{^id, document}] -> [document]
          [] -> []
        end
      end)

    {:ok, documents}
  end

  @impl BeamWeaver.Retriever
  def retrieve(%__MODULE__{} = index, query, opts) when is_binary(query) do
    top_k = Keyword.get(opts, :k, index.top_k)

    documents =
      index.table
      |> :ets.tab2list()
      |> Enum.map(fn {_id, %Document{} = document} ->
        {document, occurrence_count(document.content, query)}
      end)
      |> Enum.sort_by(fn {_document, count} -> -count end)
      |> Enum.take(top_k)
      |> Enum.map(fn {document, _count} -> document end)

    {:ok, documents}
  end

  defp occurrence_count(content, ""), do: if(content == "", do: 1, else: 0)

  defp occurrence_count(content, query) do
    content
    |> String.split(query)
    |> length()
    |> Kernel.-(1)
  end

  defp generated_id do
    "doc_" <> Integer.to_string(System.unique_integer([:positive, :monotonic]), 36)
  end
end
