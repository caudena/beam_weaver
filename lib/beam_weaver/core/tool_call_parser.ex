defmodule BeamWeaver.Core.ToolCallParser do
  @moduledoc false

  import BeamWeaver.MapAccess, only: [get: 2]

  alias BeamWeaver.Core.Messages

  @spec parse_raw_calls([map()]) ::
          {:ok,
           %{
             tool_calls: [Messages.ToolCall.t()],
             invalid_tool_calls: [Messages.InvalidToolCall.t()]
           }}
  def parse_raw_calls(raw_calls) when is_list(raw_calls) do
    {tool_calls, invalid_tool_calls} =
      Enum.reduce(raw_calls, {[], []}, fn raw_call, {tool_calls, invalid_tool_calls} ->
        case parse_raw_call(raw_call) do
          {:ok, nil} -> {tool_calls, invalid_tool_calls}
          {:ok, call} -> {[call | tool_calls], invalid_tool_calls}
          {:error, call} -> {tool_calls, [call | invalid_tool_calls]}
        end
      end)

    {:ok,
     %{
       tool_calls: Enum.reverse(tool_calls),
       invalid_tool_calls: Enum.reverse(invalid_tool_calls)
     }}
  end

  @spec parse_raw_chunks([map()]) :: {:ok, [Messages.ToolCallChunk.t()]}
  def parse_raw_chunks(raw_calls) when is_list(raw_calls) do
    {:ok, Enum.map(raw_calls, &parse_raw_chunk/1)}
  end

  @spec normalize_openai_call(term()) :: {:ok, map() | struct()} | {:error, map() | struct()}
  def normalize_openai_call(%{"type" => "function", "function" => function} = call) when is_map(function),
    do: openai_call(call["id"], function["name"], function["arguments"])

  def normalize_openai_call(%{type: :function, function: function} = call) when is_map(function),
    do: openai_call(Map.get(call, :id), Map.get(function, :name), Map.get(function, :arguments))

  def normalize_openai_call(%{} = call) do
    fields = [
      id: get(call, :id) || get(call, :call_id),
      provider_id: get(call, :provider_id),
      call_id: get(call, :call_id),
      name: get(call, :name)
    ]

    case get(call, :type) do
      type when type in [:invalid_tool_call, "invalid_tool_call"] ->
        {:error,
         Messages.invalid_tool_call(
           fields ++ [args: get(call, :args) || get(call, :arguments), error: get(call, :error)]
         )}

      type when type in [:tool_call, "tool_call", nil] ->
        if fields[:name] do
          {:ok,
           Messages.tool_call(
             fields ++
               [
                 thought_signature: get(call, :thought_signature),
                 args: get(call, :args) || get(call, :arguments) || %{}
               ]
           )}
        else
          {:ok, call}
        end

      _type ->
        {:ok, call}
    end
  end

  def normalize_openai_call(call), do: {:ok, call}

  defp parse_raw_call(raw_call) when is_map(raw_call) do
    case get(raw_call, :function) do
      nil ->
        {:ok, nil}

      function when is_map(function) ->
        name = get(function, :name)
        arguments = get(function, :arguments)

        case decode_tool_args(arguments) do
          {:ok, args} ->
            {:ok,
             Messages.tool_call(
               name: name || "",
               args: args,
               id: get(raw_call, :id)
             )}

          {:error, error} ->
            {:error,
             Messages.invalid_tool_call(
               name: name,
               args: arguments,
               id: get(raw_call, :id),
               error: error
             )}
        end
    end
  end

  defp parse_raw_call(_raw_call), do: {:ok, nil}

  defp parse_raw_chunk(raw_call) when is_map(raw_call) do
    function = get(raw_call, :function)

    Messages.tool_call_chunk(
      name: get(function, :name),
      args: get(function, :arguments),
      id: get(raw_call, :id),
      index: get(raw_call, :index)
    )
  end

  defp parse_raw_chunk(_raw_call), do: Messages.tool_call_chunk([])

  defp openai_call(id, name, arguments) when is_binary(arguments) do
    case BeamWeaver.JSON.decode(arguments) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, Messages.tool_call(id: id, provider_id: id, call_id: id, name: name, args: decoded)}

      {:ok, _decoded} ->
        {:error, invalid_call(id, name, arguments, "tool call arguments must decode to an object")}

      {:error, error} ->
        {:error, invalid_call(id, name, arguments, Exception.message(error))}
    end
  end

  defp openai_call(id, name, arguments),
    do: {:ok, Messages.tool_call(id: id, provider_id: id, call_id: id, name: name, args: arguments || %{})}

  defp invalid_call(id, name, args, error),
    do: Messages.invalid_tool_call(id: id, provider_id: id, call_id: id, name: name, args: args, error: error)

  def decode_tool_args(args) when is_binary(args) do
    case BeamWeaver.JSON.decode(args) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, decoded} ->
        {:error, "tool call arguments decoded to #{inspect(decoded)}, expected an object"}

      {:error, error} ->
        {:error, Exception.message(error)}
    end
  end

  def decode_tool_args(args), do: {:ok, args || %{}}
end
