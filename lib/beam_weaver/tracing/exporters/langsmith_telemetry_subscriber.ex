defmodule BeamWeaver.Tracing.Exporters.LangSmith.TelemetrySubscriber do
  @moduledoc """
  Telemetry subscriber that forwards BeamWeaver runtime events to LangSmith.

  This keeps LangSmith at the boundary: runtime modules emit telemetry and this
  process converts those events into queue items.
  """

  use GenServer

  alias BeamWeaver.Core.ID
  alias BeamWeaver.Tracing.Exporters.LangSmith.Queue
  alias BeamWeaver.Tracing.Run

  @events [
    [:beam_weaver, :cache, :lookup],
    [:beam_weaver, :cache, :hit],
    [:beam_weaver, :cache, :miss],
    [:beam_weaver, :cache, :put],
    [:beam_weaver, :cache, :delete],
    [:beam_weaver, :cache, :clear],
    [:beam_weaver, :cache, :sweep],
    [:beam_weaver, :checkpoint, :get_tuple],
    [:beam_weaver, :checkpoint, :list],
    [:beam_weaver, :checkpoint, :put],
    [:beam_weaver, :checkpoint, :put_writes],
    [:beam_weaver, :checkpoint, :put_checkpoint_with_writes],
    [:beam_weaver, :checkpoint, :delete_thread],
    [:beam_weaver, :checkpoint, :delete_for_runs],
    [:beam_weaver, :checkpoint, :copy_thread],
    [:beam_weaver, :checkpoint, :prune],
    [:beam_weaver, :memory, :put],
    [:beam_weaver, :memory, :get],
    [:beam_weaver, :memory, :delete],
    [:beam_weaver, :memory, :search],
    [:beam_weaver, :memory, :list_namespaces],
    [:beam_weaver, :memory, :batch],
    [:beam_weaver, :memory, :sweep],
    [:beam_weaver, :vector_store, :add_documents],
    [:beam_weaver, :vector_store, :delete],
    [:beam_weaver, :vector_store, :similarity_search],
    [:beam_weaver, :vector_store, :similarity_search_with_score],
    [:beam_weaver, :vector_store, :similarity_search_by_vector],
    [:beam_weaver, :vector_store, :max_marginal_relevance_search],
    [:beam_weaver, :models, :param_warning]
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    id = Keyword.get(opts, :id, "#{__MODULE__}-#{System.unique_integer([:positive])}")
    queue = Keyword.get(opts, :queue, Queue)

    :telemetry.attach_many(id, @events, &__MODULE__.handle_event/4, %{queue: queue})

    {:ok, %{id: id, queue: queue}}
  end

  @impl true
  def terminate(_reason, %{id: id}) do
    :telemetry.detach(id)
    :ok
  end

  def handle_event(event, measurements, metadata, %{queue: queue}) do
    run = run_from_event(event, measurements, metadata)
    status = if List.last(event) in [:exception, :error], do: :error, else: :ok
    Queue.enqueue(queue, status, run, langsmith_operation: :post)
  end

  defp run_from_event(event, measurements, metadata) do
    kind = kind(event)

    run_id =
      Map.get(metadata, :run_id) ||
        ID.uuidv7()

    trace_id = Map.get(metadata, :trace_id) || run_id

    Run.new(name(event, metadata),
      id: to_string(run_id),
      trace_id: to_string(trace_id),
      parent_id: Map.get(metadata, :parent_run_id),
      kind: kind,
      tags: [:telemetry, kind],
      inputs: %{measurements: measurements},
      metadata: Map.merge(metadata, %{telemetry_event: Enum.join(event, ".")})
    )
    |> Map.put(:status, if(List.last(event) in [:start], do: :running, else: :ok))
    |> maybe_end(event)
  end

  defp maybe_end(%Run{} = run, event) do
    if List.last(event) in [:start] do
      run
    else
      %{run | ended_at: DateTime.utc_now()}
    end
  end

  defp kind([:beam_weaver, :graph | _]), do: :graph
  defp kind([:beam_weaver, :stream | _]), do: :stream
  defp kind([:beam_weaver, :cache | _]), do: :cache
  defp kind([:beam_weaver, :checkpoint | _]), do: :checkpoint
  defp kind([:beam_weaver, :memory | _]), do: :memory
  defp kind([:beam_weaver, :vector_store | _]), do: :retriever
  defp kind([:beam_weaver, :models | _]), do: :model
  defp kind([:beam_weaver, :runnable | _]), do: :chain
  defp kind(_event), do: :operation

  defp name(event, metadata) do
    fallback = event |> Enum.drop(1) |> Enum.join(".")

    metadata
    |> Map.get(:operation, Map.get(metadata, :node, Map.get(metadata, :graph, fallback)))
    |> to_string()
  end
end
