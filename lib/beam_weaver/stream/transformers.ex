defmodule BeamWeaver.Stream.Transformers do
  @moduledoc """
  Reducer for graph data stream projections.

  A single immutable reducer over typed stream envelopes covers every stream
  mode (`:values`, `:updates`, `:custom`, `:checkpoints`, `:tasks`, `:debug`,
  `:lifecycle`). The reducer can be scoped to a graph namespace and emits
  `{mode, envelope}` tuples for the selected projection modes.
  """

  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.Stream.Namespace

  @modes [:values, :updates, :custom, :checkpoints, :tasks, :debug, :lifecycle]

  defstruct modes: MapSet.new(@modes),
            scope: [],
            include_subgraphs?: false,
            captured: []

  @type mode :: :values | :updates | :custom | :checkpoints | :tasks | :debug | :lifecycle
  @type t :: %__MODULE__{
          modes: MapSet.t(mode()),
          scope: [term()],
          include_subgraphs?: boolean(),
          captured: [{mode(), Envelope.t()}]
        }

  @spec new(mode() | [mode()] | MapSet.t(mode()), keyword() | map()) :: t()
  def new(modes \\ @modes, opts \\ []) do
    opts = if is_map(opts), do: Map.to_list(opts), else: opts

    %__MODULE__{
      modes: normalize_modes(modes),
      scope: Namespace.normalize(Keyword.get(opts, :scope, []), stringify: true),
      include_subgraphs?: Keyword.get(opts, :include_subgraphs?, false) == true
    }
  end

  @spec required_modes(t()) :: [mode()]
  def required_modes(%__MODULE__{} = transformer) do
    transformer.modes
    |> MapSet.to_list()
    |> Enum.sort()
  end

  @spec process(t(), term()) :: {:ok, t(), [{mode(), Envelope.t()}]} | {:pass, t()}
  def process(%__MODULE__{} = transformer, %Envelope{} = envelope) do
    with true <- scope_match?(transformer, envelope.namespace),
         {:ok, mode} <- mode_for(envelope.event),
         true <- MapSet.member?(transformer.modes, mode) do
      emitted = [{mode, envelope}]
      {:ok, %{transformer | captured: transformer.captured ++ emitted}, emitted}
    else
      _other -> {:pass, transformer}
    end
  end

  def process(%__MODULE__{} = transformer, _event), do: {:pass, transformer}

  @spec process_many(t(), Enumerable.t()) :: {:ok, t(), [{mode(), term()}]}
  def process_many(%__MODULE__{} = transformer, events) do
    {emitted, transformer} = Enum.flat_map_reduce(events, transformer, &step/2)
    {:ok, transformer, emitted}
  end

  @spec stream(Enumerable.t(), mode() | [mode()] | MapSet.t(mode()), keyword()) :: Enumerable.t()
  def stream(events, modes \\ @modes, opts \\ []),
    do: Elixir.Stream.transform(events, new(modes, opts), &step/2)

  defp step(event, transformer) do
    case process(transformer, event) do
      {:ok, next, emitted} -> {emitted, next}
      {:pass, next} -> {[], next}
    end
  end

  defp normalize_modes(%MapSet{} = modes), do: MapSet.intersection(modes, MapSet.new(@modes))

  defp normalize_modes(modes) do
    for mode <- List.wrap(modes),
        known = Enum.find(@modes, &(&1 == mode or Atom.to_string(&1) == mode)),
        into: MapSet.new(),
        do: known
  end

  defp mode_for(%Events.GraphValue{}), do: {:ok, :values}
  defp mode_for(%Events.GraphUpdate{}), do: {:ok, :updates}
  defp mode_for(%Events.Custom{}), do: {:ok, :custom}
  defp mode_for(%Events.Checkpoint{}), do: {:ok, :checkpoints}
  defp mode_for(%Events.Task{}), do: {:ok, :tasks}
  defp mode_for(%Events.Lifecycle{}), do: {:ok, :lifecycle}
  defp mode_for(%Events.Debug{}), do: {:ok, :debug}
  defp mode_for(%Events.Error{}), do: {:ok, :debug}
  defp mode_for(%Events.Done{}), do: {:ok, :lifecycle}
  defp mode_for(_event), do: :error

  defp scope_match?(%__MODULE__{scope: scope, include_subgraphs?: true}, namespace) do
    namespace = Namespace.normalize(namespace, stringify: true)
    Enum.take(namespace, length(scope)) == scope
  end

  defp scope_match?(%__MODULE__{scope: scope}, namespace),
    do: Namespace.normalize(namespace, stringify: true) == scope
end
