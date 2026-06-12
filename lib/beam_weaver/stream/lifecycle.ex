defmodule BeamWeaver.Stream.Lifecycle do
  @moduledoc """
  Projects typed graph stream envelopes into subgraph lifecycle events.

  The projector is intentionally a pure read-side reducer. It uses the same
  envelope data as `BeamWeaver.Stream.Subgraphs` and emits immutable lifecycle
  envelopes instead of exposing Python-style live lifecycle channels.
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
      graph: run.graph,
      namespace: run.path,
      metadata: Keyword.get(opts, :metadata, %{})
    ]

    envelope_opts =
      case first_run_id(run.path, source_events) do
        nil -> envelope_opts
        run_id -> Keyword.put(envelope_opts, :run_id, run_id)
      end

    [
      Stream.envelope(
        %Events.Lifecycle{
          status: :started,
          namespace: run.path,
          graph_name: run.graph_name,
          trigger_call_id: run.trigger_call_id
        },
        envelope_opts
      ),
      Stream.envelope(
        %Events.Lifecycle{
          status: run.status,
          namespace: run.path,
          graph_name: run.graph_name,
          trigger_call_id: run.trigger_call_id,
          error: run.error
        },
        envelope_opts
      )
    ]
  end

  defp first_run_id(path, events) do
    Enum.find_value(events, fn
      %Envelope{namespace: namespace, run_id: run_id} ->
        if Namespace.normalize(namespace, stringify: true) == path, do: run_id, else: nil

      _other ->
        nil
    end)
  end
end
