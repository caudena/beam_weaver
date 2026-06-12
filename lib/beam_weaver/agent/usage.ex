defmodule BeamWeaver.Agent.Usage do
  @moduledoc """
  Aggregates model/tool usage metadata across an agent loop.
  """

  alias BeamWeaver.Core.Message

  defstruct input_tokens: 0,
            output_tokens: 0,
            total_tokens: 0,
            model_calls: 0,
            tool_calls: 0,
            details: []

  @type t :: %__MODULE__{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          total_tokens: non_neg_integer(),
          model_calls: non_neg_integer(),
          tool_calls: non_neg_integer(),
          details: [map()]
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec from_messages([Message.t()]) :: t()
  def from_messages(messages) do
    messages
    |> List.wrap()
    |> Enum.reduce(new(), fn
      %Message{role: :assistant, usage_metadata: usage} = message, acc when is_map(usage) ->
        acc
        |> add_usage(usage)
        |> increment(:model_calls)
        |> add_detail(message.role, usage)

      %Message{role: :tool, usage_metadata: usage} = message, acc when is_map(usage) ->
        acc
        |> add_usage(usage)
        |> increment(:tool_calls)
        |> add_detail(message.role, usage)

      %Message{role: :tool}, acc ->
        increment(acc, :tool_calls)

      _message, acc ->
        acc
    end)
  end

  @spec merge(term(), term()) :: t()
  def merge(left, right) do
    left = normalize(left)
    right = normalize(right)

    %__MODULE__{
      input_tokens: left.input_tokens + right.input_tokens,
      output_tokens: left.output_tokens + right.output_tokens,
      total_tokens: left.total_tokens + right.total_tokens,
      model_calls: left.model_calls + right.model_calls,
      tool_calls: left.tool_calls + right.tool_calls,
      details: left.details ++ right.details
    }
  end

  defp add_usage(%__MODULE__{} = usage, metadata) do
    %{
      usage
      | input_tokens: usage.input_tokens + token(metadata, :input_tokens),
        output_tokens: usage.output_tokens + token(metadata, :output_tokens),
        total_tokens: usage.total_tokens + token(metadata, :total_tokens)
    }
  end

  defp add_detail(%__MODULE__{} = usage, role, metadata) do
    %{usage | details: usage.details ++ [%{role: role, usage_metadata: metadata}]}
  end

  defp increment(%__MODULE__{} = usage, field) do
    Map.update!(usage, field, &(&1 + 1))
  end

  defp normalize(%__MODULE__{} = usage), do: usage
  defp normalize(nil), do: new()
  defp normalize(messages) when is_list(messages), do: from_messages(messages)
  defp normalize(%Message{} = message), do: from_messages([message])
  defp normalize(%{} = map), do: add_usage(new(), map)
  defp normalize(_other), do: new()

  defp token(map, key) do
    value =
      Map.get(map, key) ||
        case key do
          :input_tokens -> Map.get(map, :prompt_tokens)
          :output_tokens -> Map.get(map, :completion_tokens)
          :total_tokens -> Map.get(map, :total)
        end

    if is_integer(value) and value >= 0, do: value, else: 0
  end
end
