defmodule BeamWeaver.Agent.Middleware.SubagentOutputs do
  @moduledoc """
  Declares mergeable state channels for captured specialist outputs.

  This middleware has no prompt or tools. It lets applications compose their own
  named specialist tools while storing large JSON-safe outputs outside the
  supervising model transcript.
  """

  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Channels.BinaryOperatorAggregate

  defstruct required: [],
            response: nil

  def new(opts \\ []) do
    %__MODULE__{
      required: opts |> Keyword.get(:required, []) |> normalize_required(),
      response: Keyword.get(opts, :response)
    }
  end

  @impl true
  def name(_middleware), do: :subagent_outputs

  @impl true
  def can_jump_to(_middleware, :before_model), do: [:end]
  def can_jump_to(_middleware, _hook), do: []

  @impl true
  def state_schema(_middleware) do
    %{
      subagent_outputs: Graph.channel({BinaryOperatorAggregate, &merge_maps/2}, initial: %{}),
      subagent_cache: Graph.channel({BinaryOperatorAggregate, &merge_maps/2}, initial: %{})
    }
  end

  def before_model(%__MODULE__{required: []}, _state, _runtime), do: %{}

  def before_model(%__MODULE__{} = middleware, state, _runtime) do
    outputs = state_map(state, :subagent_outputs)

    if Enum.all?(middleware.required, &Map.has_key?(outputs, &1)) do
      {:jump, :end, %{structured_response: response(middleware, outputs)}}
    else
      %{}
    end
  end

  defp merge_maps(left, right), do: Map.merge(left || %{}, right || %{})

  defp normalize_required(values) do
    values
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
  end

  defp response(%__MODULE__{response: response}, outputs) when is_function(response, 1),
    do: response.(outputs)

  defp response(%__MODULE__{response: response}, _outputs) when is_map(response),
    do: response

  defp response(%__MODULE__{response: response}, _outputs) when not is_nil(response),
    do: response

  defp response(_middleware, outputs),
    do: %{"status" => "completed", "captured_outputs" => Map.keys(outputs)}

  defp state_map(state, key) when is_map(state) do
    value = Map.get(state, key) || Map.get(state, to_string(key))
    if is_map(value), do: stringify_keys(value), else: %{}
  end

  defp state_map(_state, _key), do: %{}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
