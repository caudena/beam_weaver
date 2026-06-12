defmodule BeamWeaver.Graph.Nodes.ToolNode.Input do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message

  @spec condition(term(), atom() | String.t()) :: :tools | :end
  def condition(input, messages_key \\ :messages)

  def condition(input, messages_key) when is_map(input) do
    case fetch_messages(input, messages_key) do
      {:ok, _key, messages} -> condition(messages, messages_key)
      :error -> :end
    end
  end

  def condition(messages, _messages_key) when is_list(messages) do
    case extract(messages, :messages) do
      {:ok, [], _shape} -> :end
      {:ok, _tool_calls, _shape} -> :tools
      _error -> :end
    end
  end

  def condition(_input, _messages_key), do: :end

  @spec extract(term(), atom() | String.t()) ::
          {:ok, [map()], :list | {:state, atom() | String.t()}} | {:error, Error.t()}
  def extract(input, messages_key) when is_map(input) do
    if tool_call_with_context?(input) do
      {:ok, [Map.get(input, :tool_call) || Map.get(input, "tool_call")], :list}
    else
      case fetch_messages(input, messages_key) do
        {:ok, key, messages} when is_list(messages) ->
          extract_from_messages(messages, {:state, key})

        _other ->
          {:error, Error.new(:invalid_tool_node_input, "tool node expected messages or tool calls")}
      end
    end
  end

  def extract([%Message{} | _rest] = messages, _messages_key),
    do: extract_from_messages(messages, :list)

  def extract(tool_calls, _messages_key) when is_list(tool_calls) do
    if Enum.all?(tool_calls, &tool_call?/1) do
      {:ok, tool_calls, :list}
    else
      {:error, Error.new(:invalid_tool_node_input, "tool node expected messages or tool calls")}
    end
  end

  def extract(_input, _messages_key) do
    {:error, Error.new(:invalid_tool_node_input, "tool node expected messages or tool calls")}
  end

  @spec request_state(term(), term()) :: term()
  def request_state(input, runtime) do
    cond do
      tool_call_with_context?(input) ->
        Map.get(input, :state) || Map.get(input, "state")

      raw_tool_call_list?(input) and runtime_value(runtime, :previous_state) != nil ->
        runtime_value(runtime, :previous_state)

      true ->
        input
    end
  end

  @spec normalize_call(map()) :: %{id: term(), name: term(), args: map()}
  def normalize_call(call) do
    %{
      id: tool_call_id(call),
      name: tool_call_name(call),
      args: tool_call_args(call),
      call_id: get_value(call, :call_id),
      provider_id: get_value(call, :provider_id),
      index: get_value(call, :index)
    }
  end

  defp fetch_messages(input, key) when is_map(input) do
    cond do
      Map.has_key?(input, key) ->
        {:ok, key, Map.fetch!(input, key)}

      Map.has_key?(input, to_string(key)) ->
        {:ok, to_string(key), Map.fetch!(input, to_string(key))}

      true ->
        :error
    end
  end

  defp extract_from_messages(messages, shape) do
    messages
    |> last_ai_and_following_tool_messages()
    |> case do
      {%Message{tool_calls: tool_calls}, tool_messages} when is_list(tool_calls) ->
        tool_message_ids = MapSet.new(tool_messages, & &1.tool_call_id)

        pending =
          Enum.reject(tool_calls, fn call ->
            call
            |> tool_call_id()
            |> then(&MapSet.member?(tool_message_ids, &1))
          end)

        {:ok, pending, shape}

      _other ->
        {:ok, [], shape}
    end
  end

  defp last_ai_and_following_tool_messages(messages) do
    index =
      messages
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn
        {%Message{role: :assistant}, index} -> index
        _other -> nil
      end)

    if is_integer(index) do
      ai_message = Enum.at(messages, index)

      tool_messages =
        messages |> Enum.drop(index + 1) |> Enum.filter(&match?(%Message{role: :tool}, &1))

      {ai_message, tool_messages}
    end
  end

  defp runtime_value(nil, _field), do: nil
  defp runtime_value(runtime, field) when is_map(runtime), do: Map.get(runtime, field)

  defp tool_call?(call) do
    is_map(call) and not is_nil(tool_call_name(call))
  end

  defp raw_tool_call_list?(input) when is_list(input), do: Enum.all?(input, &tool_call?/1)
  defp raw_tool_call_list?(_input), do: false

  defp tool_call_with_context?(input) when is_map(input) do
    type = Map.get(input, :__type) || Map.get(input, "__type")
    tool_call = Map.get(input, :tool_call) || Map.get(input, "tool_call")
    state = Map.get(input, :state) || Map.get(input, "state")

    type in [:tool_call_with_context, "tool_call_with_context"] and tool_call?(tool_call) and
      is_map(state)
  end

  defp tool_call_with_context?(_input), do: false

  defp tool_call_id(call) do
    get_value(call, :call_id) || get_value(call, :tool_call_id) || get_value(call, :id)
  end

  defp tool_call_name(call) do
    get_value(call, :name) ||
      nested_value(call, :function, :name) ||
      nested_value(call, "function", "name")
  end

  defp tool_call_args(call) do
    args =
      get_value(call, :args) ||
        get_value(call, :arguments) ||
        nested_value(call, :function, :arguments) ||
        nested_value(call, "function", "arguments") ||
        %{}

    decode_args(args)
  end

  defp get_value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp nested_value(map, outer, inner) do
    case Map.get(map, outer) do
      nested when is_map(nested) -> Map.get(nested, inner) || Map.get(nested, to_string(inner))
      _other -> nil
    end
  end

  defp decode_args(args) when is_binary(args) do
    case BeamWeaver.JSON.decode(args) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _other -> %{"input" => args}
    end
  end

  defp decode_args(args) when is_map(args), do: args
  defp decode_args(_args), do: %{}
end
