defmodule BeamWeaver.Graph.Nodes.ToolNode.Output do
  @moduledoc false

  alias BeamWeaver.Agent.Usage
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Core.ToolResult
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Messages.Remove

  @spec normalize(term(), map()) :: {:ok, term()} | {:error, Error.t()}
  def normalize(%Command{} = command, call),
    do: validate_tool_command(command, call)

  def normalize(%ToolResult{} = result, call),
    do: {:ok, tool_result_message(result, call)}

  def normalize({:content_and_artifact, content, artifact}, call),
    do: {:ok, tool_result_message(ToolResult.success(content, artifact: artifact), call)}

  def normalize(%Message{} = message, call),
    do: normalize_tool_message(message, call)

  def normalize(outputs, call) when is_list(outputs) do
    if outputs != [] and Enum.all?(outputs, &tool_command_output?/1) do
      validate_tool_output_list(outputs, call)
    else
      {:ok, success_message(call, outputs)}
    end
  end

  def normalize(value, call), do: {:ok, success_message(call, value)}

  @spec return_direct(term(), term()) :: term()
  def return_direct(output, tool) do
    if Tool.return_direct(tool), do: mark_return_direct(output), else: output
  end

  @spec build([term()], :list | {:state, atom() | String.t()}) ::
          map() | [Message.t()] | Command.t()
  def build(results, output_shape) do
    usage = Usage.from_messages(Enum.filter(results, &match?(%Message{}, &1)))

    if Enum.any?(results, &match?(%Command{}, &1)) do
      command = combine_command_outputs(results)

      if usage == Usage.new() do
        command
      else
        %{command | update: Map.put(command.update || %{}, :usage, usage)}
      end
    else
      if match?({:state, _key}, output_shape) do
        {:state, key} = output_shape
        output = %{key => results}
        if usage == Usage.new(), do: output, else: Map.put(output, :usage, usage)
      else
        results
      end
    end
  end

  @spec format(term()) :: String.t()
  def format(value) when is_binary(value), do: value

  def format(value) when is_map(value) or is_list(value) do
    case BeamWeaver.JSON.encode(value) do
      {:ok, json} -> json
      {:error, _error} -> inspect(value)
    end
  end

  def format(value), do: to_string(value)

  defp validate_tool_output_list(outputs, call) do
    with {:ok, outputs} <- normalize_tool_output_items(outputs, call),
         :ok <- validate_single_terminating_message(outputs, call) do
      {:ok, outputs}
    end
  end

  defp normalize_tool_output_items(outputs, call) do
    Enum.reduce_while(outputs, {:ok, []}, fn output, {:ok, acc} ->
      normalized =
        case output do
          %Command{} = command -> validate_tool_command(command, call, false)
          %Message{} = message -> normalize_tool_message(message, call)
        end

      case normalized do
        {:ok, output} -> {:cont, {:ok, [output | acc]}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, outputs} -> {:ok, Enum.reverse(outputs)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp validate_tool_command(%Command{} = command, call, require_terminator \\ true) do
    with {:ok, command, terminator_count} <- normalize_command_messages(command, call) do
      cond do
        not require_terminator ->
          {:ok, command}

        parent_command?(command) ->
          {:ok, command}

        remove_all_messages_command?(command) ->
          {:ok, command}

        terminator_count == 1 ->
          {:ok, command}

        true ->
          {:error,
           Error.new(
             :invalid_tool_command,
             "tool command update must include exactly one matching tool message",
             %{
               tool: call.name,
               tool_call_id: call.id,
               matching_tool_messages: terminator_count
             }
           )}
      end
    end
  end

  defp normalize_command_messages(%Command{update: update} = command, call) when is_map(update) do
    case command_messages(update) do
      {key, messages} when is_list(messages) ->
        with {:ok, messages} <- normalize_command_message_list(messages, call) do
          command = %{command | update: Map.put(update, key, messages)}
          {:ok, command, matching_tool_message_count(messages, call)}
        end

      {_key, messages} ->
        {:error,
         Error.new(:invalid_tool_command, "tool command messages update must be a list", %{
           tool: call.name,
           tool_call_id: call.id,
           messages: inspect(messages)
         })}

      nil ->
        {:ok, command, 0}
    end
  end

  defp normalize_command_message_list(messages, call) do
    Enum.reduce_while(messages, {:ok, []}, fn
      %Message{} = message, {:ok, acc} ->
        case normalize_tool_message(message, call) do
          {:ok, message} -> {:cont, {:ok, [message | acc]}}
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end

      %Remove{} = remove, {:ok, acc} ->
        {:cont, {:ok, [remove | acc]}}

      message, {:ok, _acc} ->
        {:halt,
         {:error,
          Error.new(:invalid_tool_command, "tool command messages must be tool messages", %{
            tool: call.name,
            tool_call_id: call.id,
            message: inspect(message)
          })}}
    end)
    |> case do
      {:ok, messages} -> {:ok, Enum.reverse(messages)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp validate_single_terminating_message(outputs, call) do
    count =
      outputs
      |> Enum.map(&terminating_message_count(&1, call))
      |> Enum.sum()

    if count == 1 do
      :ok
    else
      {:error,
       Error.new(
         :invalid_tool_command,
         "tool output list must include exactly one matching tool message",
         %{tool: call.name, tool_call_id: call.id, matching_tool_messages: count}
       )}
    end
  end

  defp normalize_tool_message(%Message{role: :tool, tool_call_id: nil} = message, call) do
    {:ok, %{message | tool_call_id: call.id, name: message.name || call.name}}
  end

  defp normalize_tool_message(%Message{role: :tool, tool_call_id: tool_call_id} = message, call)
       when tool_call_id == call.id do
    {:ok, %{message | name: message.name || call.name}}
  end

  defp normalize_tool_message(%Message{role: :tool} = message, call) do
    {:error,
     Error.new(:invalid_tool_command, "tool message has the wrong tool_call_id", %{
       tool: call.name,
       expected_tool_call_id: call.id,
       actual_tool_call_id: message.tool_call_id
     })}
  end

  defp normalize_tool_message(%Message{} = message, call) do
    {:error,
     Error.new(:invalid_tool_command, "tool command messages must use the tool role", %{
       tool: call.name,
       tool_call_id: call.id,
       role: message.role
     })}
  end

  defp success_message(call, value) do
    Message.tool(format(value),
      tool_call_id: call.id,
      name: call.name,
      metadata: %{status: "success"}
    )
  end

  defp tool_result_message(%ToolResult{} = result, call) do
    metadata =
      result.metadata
      |> Map.put(:status, tool_status(result.status))
      |> maybe_put_artifact(result.artifact)

    Message.tool(format(result.content),
      tool_call_id: call.id,
      name: call.name,
      metadata: metadata
    )
  end

  defp tool_status(status) when is_atom(status), do: Atom.to_string(status)
  defp tool_status(status) when is_binary(status), do: status
  defp tool_status(status), do: to_string(status)

  defp maybe_put_artifact(metadata, nil), do: metadata
  defp maybe_put_artifact(metadata, artifact), do: Map.put(metadata, :artifact, artifact)

  defp mark_return_direct(%Message{metadata: %{status: "error"}} = message), do: message

  defp mark_return_direct(%Message{} = message) do
    %{message | metadata: Map.put(message.metadata || %{}, :return_direct, true)}
  end

  defp mark_return_direct(%Command{} = command) do
    update =
      command.update
      |> mark_return_direct_update()
      |> maybe_put_jump_to_end(command.goto)

    %{command | update: update}
  end

  defp mark_return_direct(outputs) when is_list(outputs),
    do: Enum.map(outputs, &mark_return_direct/1)

  defp mark_return_direct(output), do: output

  defp mark_return_direct_update(update) when is_map(update) do
    case command_messages(update) do
      {key, messages} when is_list(messages) ->
        Map.put(update, key, Enum.map(messages, &mark_return_direct/1))

      _other ->
        update
    end
  end

  defp mark_return_direct_update(_update), do: %{}

  defp maybe_put_jump_to_end(update, nil), do: Map.put_new(update, :jump_to, :end)
  defp maybe_put_jump_to_end(update, _goto), do: update

  defp combine_command_outputs(results) do
    Enum.reduce(results, %Command{}, fn
      %Command{} = command, acc -> merge_command(acc, command)
      %Message{} = message, acc -> merge_command(acc, %Command{update: %{messages: [message]}})
    end)
  end

  defp merge_command(%Command{} = acc, %Command{} = command) do
    %Command{
      update: merge_command_updates(acc.update || %{}, command.update || %{}),
      goto: merge_goto(acc.goto, command.goto),
      resume: acc.resume || command.resume,
      graph: acc.graph || command.graph
    }
  end

  defp merge_command_updates(left, right) do
    {left_messages, left} = pop_messages_update(left)
    {right_messages, right} = pop_messages_update(right)

    merged = Map.merge(left, right)
    messages = left_messages ++ right_messages

    if messages == [] do
      merged
    else
      Map.put(merged, :messages, messages)
    end
  end

  defp merge_goto(nil, goto), do: goto
  defp merge_goto(goto, nil), do: goto
  defp merge_goto(left, right), do: List.wrap(left) ++ List.wrap(right)

  defp pop_messages_update(update) do
    case command_messages(update) do
      {key, messages} when is_list(messages) -> {messages, Map.delete(update, key)}
      _other -> {[], update}
    end
  end

  defp tool_command_output?(%Command{}), do: true
  defp tool_command_output?(%Message{}), do: true
  defp tool_command_output?(_output), do: false

  defp terminating_message_count(%Message{} = message, call),
    do: matching_tool_message_count([message], call)

  defp terminating_message_count(%Command{update: update}, call) when is_map(update) do
    case command_messages(update) do
      {_key, messages} when is_list(messages) -> matching_tool_message_count(messages, call)
      _other -> 0
    end
  end

  defp matching_tool_message_count(messages, call) do
    Enum.count(messages, fn
      %Message{role: :tool, tool_call_id: tool_call_id} -> tool_call_id == call.id
      _other -> false
    end)
  end

  defp command_messages(update) when is_map(update) do
    cond do
      Map.has_key?(update, :messages) -> {:messages, Map.fetch!(update, :messages)}
      Map.has_key?(update, "messages") -> {"messages", Map.fetch!(update, "messages")}
      true -> nil
    end
  end

  defp parent_command?(%Command{graph: graph}),
    do: graph in [Command.parent(), "parent", "__parent__"]

  defp remove_all_messages_command?(%Command{update: update}) when is_map(update) do
    case command_messages(update) do
      {_key, messages} when is_list(messages) ->
        Enum.any?(messages, &match?(%Remove{id: "__remove_all__"}, &1))

      _other ->
        false
    end
  end
end
