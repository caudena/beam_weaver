defmodule BeamWeaver.Agent.Nodes.Model.Prompt do
  @moduledoc false

  alias BeamWeaver.Agent.State
  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message

  def state_messages(state) do
    messages = State.messages(state)

    if is_list(messages) do
      with :ok <- ChatModel.validate_messages(messages), do: {:ok, messages}
    else
      {:error,
       Error.new(:invalid_agent_state, "agent state messages must be a list", %{
         messages: inspect(messages)
       })}
    end
  end

  # A reply whose tool-call arguments came back malformed or truncated keeps
  # them as invalid calls, which no tool runs. Each one gets an error tool
  # message right after its assistant message before the next model call, so
  # the model learns the call failed and the provider sees every call it was
  # sent answered.
  def answer_invalid_tool_calls(messages) do
    answered = for %Message{role: :tool, tool_call_id: id} <- messages, not is_nil(id), into: MapSet.new(), do: id

    {messages, _answered} =
      Enum.flat_map_reduce(messages, answered, fn
        %Message{role: :assistant} = message, answered ->
          {answers, answered} = invalid_call_answers(message, answered)
          {[message | answers], answered}

        message, answered ->
          {[message], answered}
      end)

    messages
  end

  defp invalid_call_answers(%Message{metadata: metadata}, answered) do
    calls = if is_map(metadata), do: Map.get(metadata, :invalid_tool_calls) || [], else: []

    Enum.reduce(calls, {[], answered}, fn call, {answers, answered} ->
      id = if is_map(call), do: BeamWeaver.Agent.Nodes.Model.Response.tool_call_id(call)

      if is_nil(id) or MapSet.member?(answered, id) do
        {answers, answered}
      else
        name = Map.get(call, :name) || "unknown"

        answer =
          Message.tool(
            "Tool call #{name} with id #{id} could not be executed - arguments were malformed or truncated.",
            tool_call_id: id,
            name: name,
            metadata: %{status: "error", error_type: :invalid_tool_call}
          )

        {answers ++ [answer], MapSet.put(answered, id)}
      end
    end)
  end

  def validate_chat_history(messages) do
    tool_results =
      messages
      |> Enum.filter(&match?(%Message{role: :tool}, &1))
      |> Enum.map(& &1.tool_call_id)
      |> MapSet.new()

    missing =
      for %Message{role: :assistant, tool_calls: tool_calls} <- messages,
          call <- tool_calls || [],
          id = tool_call_id(call),
          not is_nil(id),
          not MapSet.member?(tool_results, id),
          do: call

    if missing == [] do
      :ok
    else
      {:error,
       Error.new(
         :invalid_chat_history,
         "assistant tool calls must have matching tool messages",
         %{
           missing_tool_calls: Enum.take(missing, 3)
         }
       )}
    end
  end

  def system_message(nil), do: {:ok, nil}
  def system_message(%Message{role: :system} = prompt), do: {:ok, prompt}
  def system_message(prompt) when is_binary(prompt), do: {:ok, Message.system(prompt)}

  def system_message(prompts) when is_list(prompts) do
    if Enum.all?(prompts, &match?(%Message{}, &1)) do
      {:ok, prompts}
    else
      {:error,
       Error.new(:invalid_system_prompt, "system_prompt message list contains invalid entries", %{
         prompt: inspect(prompts)
       })}
    end
  end

  def system_message(prompt) do
    {:error,
     Error.new(
       :invalid_system_prompt,
       "system_prompt must be a string, system message, message list, or nil; use DynamicPrompt middleware for dynamic prompts",
       %{
         prompt: inspect(prompt)
       }
     )}
  end

  def model_opts(node, runtime) do
    node.model_opts
    |> Keyword.drop([:tool_timeout])
    |> Keyword.merge(runtime_model_opts(runtime))
    |> Keyword.put_new(:tools, node.tools)
    |> Keyword.put_new(:context, Map.get(runtime || %{}, :context))
    |> Keyword.put_new(:cache, Map.get(runtime || %{}, :cache))
    |> Keyword.put_new(:assistant_name, node.assistant_name)
  end

  @runtime_model_opt_blocklist [:tools, :context, :cache, :assistant_name, :tool_timeout]

  defp runtime_model_opts(%{model_opts: opts}), do: sanitize_runtime_model_opts(opts)
  defp runtime_model_opts(_runtime), do: []

  defp sanitize_runtime_model_opts(opts) when is_list(opts) do
    opts
    |> Enum.filter(fn {key, _value} -> is_atom(key) end)
    |> Keyword.drop(@runtime_model_opt_blocklist)
  end

  defp sanitize_runtime_model_opts(opts) when is_map(opts) do
    opts
    |> Enum.filter(fn {key, _value} -> is_atom(key) end)
    |> Keyword.new()
    |> Keyword.drop(@runtime_model_opt_blocklist)
  end

  defp sanitize_runtime_model_opts(_opts), do: []

  def prompt_messages(nil), do: []
  def prompt_messages(messages) when is_list(messages), do: messages
  def prompt_messages(%Message{} = message), do: [message]

  def tool_call_id(call), do: Map.get(call, :call_id) || Map.get(call, :tool_call_id) || Map.get(call, :id)
end
