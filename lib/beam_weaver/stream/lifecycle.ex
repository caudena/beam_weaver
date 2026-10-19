defmodule BeamWeaver.Stream.Lifecycle do
  @moduledoc """
  Projects typed graph stream envelopes into subgraph lifecycle events.

  The projector is intentionally a pure read-side reducer. It uses the same
  envelope data as `BeamWeaver.Stream.Subgraphs` and emits two immutable
  lifecycle envelopes per subgraph run, in the subgraph's namespace:
  `:started`, then the status `BeamWeaver.Stream.Subgraphs` gives the run
  (`:completed`, `:failed` or `:interrupted`).
  """

  alias BeamWeaver.Stream
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.Stream.Namespace
  alias BeamWeaver.Stream.Subgraphs

  @type lifecycle_status :: :started | :completed | :failed | :interrupted

  @spec from_events(Enumerable.t(), keyword() | map()) :: [Envelope.t()]
  def from_events(events, opts \\ []) do
    opts = if is_map(opts), do: Map.to_list(opts), else: opts
    source_events = Enum.to_list(events)

    source_events
    |> Subgraphs.from_events(scope: Keyword.get(opts, :scope, []))
    |> Subgraphs.flatten()
    |> Enum.flat_map(&run_events(&1, source_events, opts))
  end

  defp run_events(run, source_events, opts) do
    envelope_opts = [
      run_id: first_run_id(run.path, source_events),
      graph: run.graph,
      namespace: run.path,
      metadata: Keyword.get(opts, :metadata, %{})
    ]

    started = %Events.Lifecycle{
      status: :started,
      namespace: run.path,
      graph_name: run.graph_name,
      trigger_call_id: run.trigger_call_id
    }

    [
      Stream.envelope(started, envelope_opts),
      Stream.envelope(%{started | status: run.status, error: run.error}, envelope_opts)
    ]
  end

  defp first_run_id(path, events) do
    Enum.find_value(events, fn %Envelope{namespace: namespace, run_id: run_id} ->
      if Namespace.normalize(namespace, stringify: true) == path, do: run_id
    end)
  end
end
