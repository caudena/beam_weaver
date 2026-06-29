defmodule BeamWeaver.Agent.Nodes.Model.Prompt do
  @moduledoc false

  alias BeamWeaver.Agent.State
  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message

  def state_messages(state) do
    messages = State.messages(state)

    if is_list(messages) do
      case ChatModel.validate_messages(messages) do
        :ok -> {:ok, messages}
        {:error, %Error{} = error} -> {:error, error}
      end
    else
      {:error,
       Error.new(:invalid_agent_state, "agent state messages must be a list", %{
         messages: inspect(messages)
       })}
    end
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

  def system_message(nil, _state, _runtime), do: {:ok, nil}

  def system_message(%Message{role: :system} = prompt, _state, _runtime) do
    {:ok, prompt}
  end

  def system_message(prompt, _state, _runtime) when is_binary(prompt) do
    {:ok, Message.system(prompt)}
  end

  def system_message(prompts, _state, _runtime) when is_list(prompts) do
    if Enum.all?(prompts, &match?(%Message{}, &1)) do
      {:ok, prompts}
    else
      {:error,
       Error.new(:invalid_system_prompt, "system_prompt message list contains invalid entries", %{
         prompt: inspect(prompts)
       })}
    end
  end

  def system_message(prompt, _state, _runtime) do
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

  defp tool_call_id(call) do
    Map.get(call, :call_id) ||
      Map.get(call, :tool_call_id) ||
      Map.get(call, :id)
  end
end
