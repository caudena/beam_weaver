defmodule BeamWeaver.Agent.Compiler.Routing do
  @moduledoc false

  alias BeamWeaver.Agent.Nodes.Model.Prompt
  alias BeamWeaver.Agent.State
  alias BeamWeaver.Agent.StructuredOutput.ResultHandler
  alias BeamWeaver.Graph.Send

  def model_router(state), do: State.jump_to(state) || route_model_messages(state)

  # A tool's jump to the model sends the results to it, also from a tool that
  # returns directly; a jump to the tools has nothing to run here.
  def tools_router(state) do
    case State.jump_to(state) do
      jump when jump in [:end, :model] -> jump
      _tools_or_none -> route_tools_result(state)
    end
  end

  def validation_router(state) do
    messages = State.messages(state)

    cond do
      jump = State.jump_to(state) -> jump
      validation_error_after_latest_assistant?(messages) -> :model
      pending_tool_calls(messages) != [] -> :tools
      true -> :end
    end
  end

  # Between two `after_model` hooks: a jump to the model or the end skips the
  # hooks left, and anything else goes to the next hook. Tool calls, also
  # after a jump to the tools, reach the tools only once every hook, such as
  # a review, has seen them; the last hook's router sends them there.
  # A router that goes to the tools node sends each pending tool call there as
  # a task of its own instead, so a review can pause each call on its own.
  # With no call pending, it goes to the tools node as usual.
  def sending_tool_calls(router) do
    fn state ->
      with :tools <- router.(state) do
        case pending_tool_calls(State.messages(state)) do
          [] -> :tools
          calls -> Enum.map(calls, &%Send{node: :tools, update: %{__type: :tool_call_with_context, tool_call: &1}})
        end
      end
    end
  end

  def after_model_router(state, next) do
    case State.jump_to(state) do
      target when target in [:model, :end] -> target
      _tools_or_none -> next
    end
  end

  def middleware_router(state, default), do: State.jump_to(state) || route_middleware_messages(state, default)

  defp route_middleware_messages(state, default) do
    messages = State.messages(state)

    cond do
      pending_tool_calls(messages) != [] ->
        :tools

      State.structured_response?(state) ->
        :end

      true ->
        default
    end
  end

  # A structured answer that failed ends on its error, a tool message or, for
  # an answer that called no tool, a user message: the model answers again.
  defp route_model_messages(state) do
    messages = State.messages(state)

    cond do
      pending_tool_calls(messages) != [] ->
        :tools

      State.structured_response?(state) ->
        :end

      latest_ai_has_tool_calls?(messages) ->
        :model

      structured_output_retry?(messages) ->
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

  defp structured_output_retry?([_ | _] = messages),
    do: ResultHandler.structured_output_error?(List.last(messages))

  defp structured_output_retry?(_messages), do: false

  defp pending_tool_calls(messages) when is_list(messages) do
    case last_ai_and_following_tool_messages(messages) do
      {%{tool_calls: calls}, tool_messages} when is_list(calls) ->
        tool_message_ids = MapSet.new(tool_messages, & &1.tool_call_id)
        Enum.reject(calls, &MapSet.member?(tool_message_ids, Prompt.tool_call_id(&1)))

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

  defp last_ai_and_following_tool_messages(messages) do
    case messages |> Enum.reverse() |> Enum.split_while(&(not match?(%{role: :assistant}, &1))) do
      {following, [ai_message | _earlier]} -> {ai_message, Enum.filter(following, &match?(%{role: :tool}, &1))}
      {_messages, []} -> nil
    end
  end

  # The run ends on the tools' results only when every call of the batch ran
  # a tool that returns directly; any other result goes back to the model.
  defp return_direct_tool_result?(state) do
    case state |> State.messages() |> last_tool_messages() do
      [] -> false
      messages -> Enum.all?(messages, &match?(%{metadata: %{return_direct: true}}, &1))
    end
  end

  defp last_tool_messages(messages) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.take_while(&match?(%{role: :tool}, &1))
  end

  defp last_tool_messages(_messages), do: []

  defp validation_error_after_latest_assistant?(messages),
    do: messages |> last_tool_messages() |> Enum.any?(&match?(%{metadata: %{is_error: true}}, &1))
end
