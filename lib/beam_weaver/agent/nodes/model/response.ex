defmodule BeamWeaver.Agent.Nodes.Model.Response do
  @moduledoc false

  alias BeamWeaver.Agent.ExtendedModelResponse
  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Agent.ModelResponse
  alias BeamWeaver.Agent.ToolSet
  alias BeamWeaver.Agent.Usage
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Graph.Command

  def normalize_model_result({:ok, %ModelResponse{}} = result), do: result

  def normalize_model_result({:ok, %ExtendedModelResponse{} = response}),
    do: normalize_model_result(response)

  def normalize_model_result({:error, %Error{}} = error), do: error
  def normalize_model_result(%ModelResponse{} = response), do: {:ok, response}

  def normalize_model_result(%ExtendedModelResponse{
        model_response: %ModelResponse{} = response,
        command: nil
      }),
      do: {:ok, response}

  def normalize_model_result(%ExtendedModelResponse{
        model_response: %ModelResponse{} = response,
        command: %Command{} = command
      }) do
    {:ok, append_response_command(response, command)}
  end

  def normalize_model_result(%Message{} = message),
    do: {:ok, %ModelResponse{messages: [message]}}

  def normalize_model_result(other) do
    {:error,
     Error.new(:invalid_model_response, "model middleware returned an invalid response", %{
       returned: inspect(other)
     })}
  end

  def to_update(%ModelResponse{commands: commands} = response) when commands != [] do
    [base_response_update(response) | commands]
  end

  def to_update(%ModelResponse{} = response), do: base_response_update(response)

  def to_update({:ok, response}), do: to_update(response)

  def attach_runtime_metadata(%ModelResponse{} = response, %ToolSet{} = tool_set) do
    %{response | tool_set: tool_set, usage: Usage.from_messages(response.messages)}
  end

  def put_agent_name(%ModelResponse{} = response, %ModelRequest{model_opts: opts}) do
    case Keyword.get(opts, :agent_name) do
      nil ->
        response

      name ->
        %{response | messages: Enum.map(response.messages, &put_agent_name_to_message(&1, name))}
    end
  end

  def maybe_limit_steps_response(
        %ModelRequest{} = request,
        %ModelResponse{messages: [%Message{} = message | _rest]} = response
      ) do
    if more_steps_needed?(request, message) do
      %ModelResponse{messages: [step_limit_message(message)]}
    else
      response
    end
  end

  def maybe_limit_steps_response(_request, response), do: response

  defp base_response_update(%ModelResponse{} = response) do
    %{messages: response.messages}
    |> maybe_put_structured_response(response.structured_response)
    |> maybe_put_tool_set(response.tool_set)
    |> maybe_put_usage(response.usage)
  end

  defp maybe_put_structured_response(update, nil), do: update

  defp maybe_put_structured_response(update, value),
    do: Map.put(update, :structured_response, value)

  defp maybe_put_tool_set(update, nil), do: update
  defp maybe_put_tool_set(update, %ToolSet{} = tool_set), do: Map.put(update, :tool_set, tool_set)

  defp maybe_put_usage(update, nil), do: update
  defp maybe_put_usage(update, %Usage{} = usage), do: Map.put(update, :usage, usage)

  defp append_response_command(%ModelResponse{} = response, %Command{} = command) do
    %{
      response
      | commands: response.commands ++ [%{command | update: normalize_command_update(command.update)}]
    }
  end

  defp put_agent_name_to_message(%Message{role: :assistant, name: nil} = message, name),
    do: %{message | name: to_string(name)}

  defp put_agent_name_to_message(message, _name), do: message

  defp more_steps_needed?(
         %ModelRequest{state: state, runtime: runtime, tools: tools, tool_set: tool_set},
         %Message{role: :assistant, tool_calls: tool_calls}
       ) do
    remaining_steps =
      state_value(state, :remaining_steps) || runtime_value(runtime, :recursion_limit)

    if is_integer(remaining_steps) do
      tool_calls = tool_calls || []
      has_tool_calls? = tool_calls != []
      tools = if tool_set, do: ToolSet.list(tool_set), else: tools
      all_return_direct? = Enum.all?(tool_calls, &return_direct_tool?(&1, tools))

      (remaining_steps < 1 and all_return_direct?) or
        (remaining_steps < 2 and has_tool_calls?)
    else
      false
    end
  end

  defp more_steps_needed?(_request, _message), do: false

  defp step_limit_message(%Message{} = response) do
    Message.assistant("Sorry, need more steps to process this request.", id: response.id)
  end

  defp return_direct_tool?(call, tools) do
    name = Map.get(call, :name)

    Enum.any?(tools, fn tool ->
      Tool.name(tool) == name and Tool.return_direct(tool)
    end)
  end

  defp state_value(state, key) when is_map(state) do
    Map.get(state, key, Map.get(state, to_string(key)))
  end

  defp runtime_value(runtime, key) when is_map(runtime), do: Map.get(runtime, key)
  defp runtime_value(_runtime, _key), do: nil

  defp normalize_command_update(update) when is_map(update), do: update
  defp normalize_command_update(_update), do: %{}
end
