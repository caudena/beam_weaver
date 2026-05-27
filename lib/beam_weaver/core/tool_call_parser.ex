defmodule BeamWeaver.Core.ToolCallParser do
  @moduledoc false

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

  @spec normalize_openai_call(term(), atom()) :: {:ok, map() | struct()} | {:error, map() | struct()}
  def normalize_openai_call(%{"type" => "function", "function" => function} = call, :string_keys)
      when is_map(function) do
    openai_call(call["id"], function["name"], function["arguments"], :string_keys)
  end

  def normalize_openai_call(%{"type" => "function", "function" => function} = call, :atom_keys)
      when is_map(function) do
    openai_call(call["id"], function["name"], function["arguments"], :atom_keys)
  end

  def normalize_openai_call(%{type: :function, function: function} = call, :atom_keys)
      when is_map(function) do
    openai_call(
      Map.get(call, :id),
      Map.get(function, :name),
      Map.get(function, :arguments),
      :atom_keys
    )
  end

  def normalize_openai_call(%{} = call, :atom_keys) do
    case BeamWeaver.MapAccess.get(call, :type) do
      type when type in [:invalid_tool_call, "invalid_tool_call"] ->
        {:error,
         Messages.invalid_tool_call(
           id: BeamWeaver.MapAccess.get(call, :id) || BeamWeaver.MapAccess.get(call, :call_id),
           provider_id: BeamWeaver.MapAccess.get(call, :provider_id),
           call_id: BeamWeaver.MapAccess.get(call, :call_id),
           name: BeamWeaver.MapAccess.get(call, :name),
           args: BeamWeaver.MapAccess.get(call, :args) || BeamWeaver.MapAccess.get(call, :arguments),
           error: BeamWeaver.MapAccess.get(call, :error)
         )}

      type when type in [:tool_call, "tool_call", nil] ->
        if BeamWeaver.MapAccess.get(call, :name) do
          {:ok,
           Messages.tool_call(
             id: BeamWeaver.MapAccess.get(call, :id) || BeamWeaver.MapAccess.get(call, :call_id),
             provider_id: BeamWeaver.MapAccess.get(call, :provider_id),
             call_id: BeamWeaver.MapAccess.get(call, :call_id),
             name: BeamWeaver.MapAccess.get(call, :name),
             args:
               BeamWeaver.MapAccess.get(call, :args) ||
                 BeamWeaver.MapAccess.get(call, :arguments) || %{}
           )}
        else
          {:ok, call}
        end

      _type ->
        {:ok, call}
    end
  end

  def normalize_openai_call(call, _key_kind), do: {:ok, call}

  defp parse_raw_call(raw_call) when is_map(raw_call) do
    case BeamWeaver.MapAccess.get(raw_call, :function) do
      nil ->
        {:ok, nil}

      function when is_map(function) ->
        name = BeamWeaver.MapAccess.get(function, :name)
        arguments = BeamWeaver.MapAccess.get(function, :arguments)

        case decode_tool_args(arguments) do
          {:ok, args} ->
            {:ok,
             Messages.tool_call(
               name: name || "",
               args: args,
               id: BeamWeaver.MapAccess.get(raw_call, :id)
             )}

          {:error, error} ->
            {:error,
             Messages.invalid_tool_call(
               name: name,
               args: arguments,
               id: BeamWeaver.MapAccess.get(raw_call, :id),
               error: error
             )}
        end
    end
  end

  defp parse_raw_call(_raw_call), do: {:ok, nil}

  defp parse_raw_chunk(raw_call) when is_map(raw_call) do
    function = BeamWeaver.MapAccess.get(raw_call, :function)

    Messages.tool_call_chunk(
      name: if(is_map(function), do: BeamWeaver.MapAccess.get(function, :name)),
      args: if(is_map(function), do: BeamWeaver.MapAccess.get(function, :arguments)),
      id: BeamWeaver.MapAccess.get(raw_call, :id),
      index: BeamWeaver.MapAccess.get(raw_call, :index)
    )
  end

  defp parse_raw_chunk(_raw_call), do: Messages.tool_call_chunk([])

  defp openai_call(id, name, nil, key_kind), do: openai_call(id, name, "{}", key_kind)

  defp openai_call(id, name, arguments, key_kind) when is_binary(arguments) do
    case BeamWeaver.JSON.decode(arguments) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, call_map(key_kind, :tool_call, id, name, decoded)}

      {:ok, _decoded} ->
        {:error,
         call_map(
           key_kind,
           :invalid_tool_call,
           id,
           name,
           arguments,
           "tool call arguments must decode to an object"
         )}

      {:error, error} ->
        {:error, call_map(key_kind, :invalid_tool_call, id, name, arguments, Exception.message(error))}
    end
  end

  defp openai_call(id, name, arguments, key_kind) do
    {:ok, call_map(key_kind, :tool_call, id, name, arguments || %{})}
  end

  defp call_map(:string_keys, type, id, name, args) do
    %{"type" => Atom.to_string(type), "id" => id, "name" => name, "args" => args}
    |> BeamWeaver.MapShape.compact()
  end

  defp call_map(:atom_keys, :tool_call, id, name, args),
    do: Messages.tool_call(id: id, provider_id: id, call_id: id, name: name, args: args)

  defp call_map(:string_keys, type, id, name, args, error) do
    %{
      "type" => Atom.to_string(type),
      "id" => id,
      "name" => name,
      "args" => args,
      "error" => error
    }
    |> BeamWeaver.MapShape.compact()
  end

  defp call_map(:atom_keys, :invalid_tool_call, id, name, args, error) do
    Messages.invalid_tool_call(
      id: id,
      provider_id: id,
      call_id: id,
      name: name,
      args: args,
      error: error
    )
  end

  defp decode_tool_args(nil), do: {:ok, %{}}
  defp decode_tool_args(args) when is_map(args), do: {:ok, args}

  defp decode_tool_args(args) when is_binary(args) do
    case BeamWeaver.JSON.decode(args) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, decoded} ->
        {:error, "tool call arguments decoded to #{inspect(decoded)}, expected an object"}

      {:error, error} ->
        {:error, Exception.message(error)}
    end
  end

  defp decode_tool_args(args), do: {:ok, args || %{}}
end
