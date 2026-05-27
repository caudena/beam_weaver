defmodule BeamWeaver.Agent.Compiler.Routing do
  @moduledoc false

  alias BeamWeaver.Agent.State

  def model_router(state) do
    case State.jump_to(state) do
      :model -> :model
      :tools -> :tools
      :end -> :end
      _other -> route_model_messages(state)
    end
  end

  def tools_router(state) do
    case State.jump_to(state) do
      :end -> :end
      _other -> route_tools_result(state)
    end
  end

  def validation_router(state) do
    case State.jump_to(state) do
      :model ->
        :model

      :tools ->
        :tools

      :end ->
        :end

      _other ->
        messages = State.messages(state)

        cond do
          validation_error_after_latest_assistant?(messages) ->
            :model

          pending_tool_calls(messages) != [] ->
            :tools

          true ->
            :end
        end
    end
  end

  def middleware_router(state, default) do
    case State.jump_to(state) do
      :model -> :model
      :tools -> :tools
      :end -> :end
      _other -> default
    end
  end

  defp route_model_messages(state) do
    messages = State.messages(state)

    cond do
      pending_tool_calls(messages) != [] ->
        :tools

      State.structured_response?(state) ->
        :end

      latest_ai_has_tool_calls?(messages) ->
        :model

      true ->
        :end
    end
  end

  defp route_tools_result(state) do
    messages = State.messages(state)

    cond do
      return_direct_tool_result?(state) ->
        :end

      State.structured_response?(state) and pending_tool_calls(messages) == [] ->
        :end

      true ->
        :model
    end
  end

  defp pending_tool_calls(messages) when is_list(messages) do
    case last_ai_and_following_tool_messages(messages) do
      {%{tool_calls: calls}, tool_messages} when is_list(calls) ->
        tool_message_ids =
          tool_messages
          |> Enum.map(& &1.tool_call_id)
          |> MapSet.new()

        Enum.reject(calls, fn call ->
          id = tool_call_id(call)
          MapSet.member?(tool_message_ids, id)
        end)

      _other ->
        []
    end
  end

  defp pending_tool_calls(_messages), do: []

  defp latest_ai_has_tool_calls?(messages) when is_list(messages) do
    case last_ai_and_following_tool_messages(messages) do
      {%{tool_calls: calls}, _tool_messages} when is_list(calls) -> calls != []
      _other -> false
    end
  end

  defp latest_ai_has_tool_calls?(_messages), do: false

  defp tool_call_id(call) do
    Map.get(call, :call_id) ||
      Map.get(call, :tool_call_id) ||
      Map.get(call, :id)
  end

  defp last_ai_and_following_tool_messages(messages) do
    index =
      messages
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn
        {%{role: :assistant}, index} -> index
        _other -> nil
      end)

    if is_integer(index) do
      ai_message = Enum.at(messages, index)
      tool_messages = messages |> Enum.drop(index + 1) |> Enum.filter(&match?(%{role: :tool}, &1))
      {ai_message, tool_messages}
    end
  end

  defp return_direct_tool_result?(state) do
    state
    |> State.messages()
    |> last_tool_messages()
    |> Enum.any?(fn message ->
      metadata = Map.get(message, :metadata, %{}) || %{}
      Map.get(metadata, :return_direct) == true
    end)
  end

  defp last_tool_messages(messages) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.take_while(&match?(%{role: :tool}, &1))
  end

  defp last_tool_messages(_messages), do: []

  defp validation_error_after_latest_assistant?(messages) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.take_while(&match?(%{role: :tool}, &1))
    |> Enum.any?(fn message ->
      metadata = Map.get(message, :metadata, %{}) || %{}
      Map.get(metadata, :is_error) == true
    end)
  end

  defp validation_error_after_latest_assistant?(_messages), do: false
end
