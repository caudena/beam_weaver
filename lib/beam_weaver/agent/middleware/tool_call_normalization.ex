defmodule BeamWeaver.Agent.Middleware.ToolCallNormalization do
  @moduledoc "Normalizes provider tool calls into the shape BeamWeaver expects."

  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Agent.ModelResponse
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages
  alias BeamWeaver.Core.Messages.ToolCall

  defstruct max_argument_chars: 20_000

  @impl true
  def name(_middleware), do: :deepagents_patch_tool_calls

  def new(opts \\ []),
    do: %__MODULE__{max_argument_chars: Keyword.get(opts, :max_argument_chars, 20_000)}

  def wrap_model_call(%__MODULE__{} = middleware, %ModelRequest{} = request, handler) do
    case handler.(request) do
      {:ok, %ModelResponse{} = response} ->
        {:ok, %{response | messages: Enum.map(response.messages, &patch_message(&1, middleware))}}

      other ->
        other
    end
  end

  defp patch_message(%Message{role: :assistant, tool_calls: calls} = message, middleware)
       when is_list(calls) do
    %{message | tool_calls: Enum.with_index(calls, &patch_tool_call(&1, &2, middleware))}
  end

  defp patch_message(message, _middleware), do: message

  defp patch_tool_call(%ToolCall{} = call, index, %__MODULE__{} = middleware) do
    patch_atom_tool_call(Map.from_struct(call), index, middleware)
  end

  defp patch_tool_call(%{__struct__: _module} = call, index, %__MODULE__{} = middleware) do
    call
    |> Map.from_struct()
    |> patch_atom_tool_call(index, middleware)
  rescue
    _exception ->
      Messages.tool_call(id: sanitize_tool_call_id(nil, index), name: "unknown_tool", args: %{})
  end

  defp patch_tool_call(call, index, %__MODULE__{} = middleware) when is_map(call) do
    call
    |> project_public_tool_call()
    |> patch_atom_tool_call(index, middleware)
  end

  defp patch_tool_call(_call, index, _middleware) do
    Messages.tool_call(id: sanitize_tool_call_id(nil, index), name: "unknown_tool", args: %{})
  end

  defp patch_atom_tool_call(call, index, %__MODULE__{} = middleware) when is_map(call) do
    id = Map.get(call, :id) || Map.get(call, :call_id)

    Messages.tool_call(
      id: sanitize_tool_call_id(id, index),
      provider_id: Map.get(call, :provider_id),
      call_id: Map.get(call, :call_id),
      name: sanitize_name(Map.get(call, :name)),
      thought_signature: Map.get(call, :thought_signature),
      args: call |> call_args() |> truncate_args(middleware.max_argument_chars)
    )
  end

  defp project_public_tool_call(%{} = public_call) do
    %{
      id: Map.get(public_call, :id) || Map.get(public_call, "id"),
      provider_id: Map.get(public_call, :provider_id) || Map.get(public_call, "provider_id"),
      call_id: Map.get(public_call, :call_id) || Map.get(public_call, "call_id"),
      name: Map.get(public_call, :name) || Map.get(public_call, "name"),
      thought_signature:
        Map.get(public_call, :thought_signature) || Map.get(public_call, "thought_signature") ||
          Map.get(public_call, :thoughtSignature) || Map.get(public_call, "thoughtSignature"),
      args:
        Map.get(public_call, :args) || Map.get(public_call, "args") ||
          Map.get(public_call, :arguments) || Map.get(public_call, "arguments") || %{}
    }
  end

  defp call_args(call) do
    args = Map.get(call, :args, %{})

    cond do
      is_map(args) ->
        args

      is_binary(args) ->
        case BeamWeaver.JSON.decode(args) do
          {:ok, decoded} when is_map(decoded) -> decoded
          _error -> %{"input" => args}
        end

      true ->
        %{"input" => inspect(args)}
    end
  end

  defp sanitize_tool_call_id(nil, index), do: "call_#{index}"

  defp sanitize_tool_call_id(id, index) do
    id
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_-]/, "_")
    |> String.slice(0, 64)
    |> case do
      "" -> "call_#{index}"
      sanitized -> sanitized
    end
  end

  defp sanitize_name(nil), do: "unknown_tool"
  defp sanitize_name(name), do: to_string(name)

  defp truncate_args(value, :unlimited), do: value

  defp truncate_args(value, max) when is_map(value),
    do: Map.new(value, &truncate_arg_pair(&1, max))

  defp truncate_args(value, max) when is_list(value), do: Enum.map(value, &truncate_args(&1, max))

  defp truncate_args(value, max)
       when is_binary(value) and is_integer(max) and byte_size(value) > max,
       do: binary_part(value, 0, max) <> "\n\n... argument truncated at #{max} bytes."

  defp truncate_args(value, _max), do: value

  defp truncate_arg_pair({key, value}, max), do: {key, truncate_args(value, max)}
end
