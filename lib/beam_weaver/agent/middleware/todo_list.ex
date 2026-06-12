defmodule BeamWeaver.Agent.Middleware.TodoList do
  @moduledoc """
  Adds a native TODO planning tool and prompt guidance to an agent.

  BeamWeaver keeps TODO planning as a normal tool plus middleware prompt/policy
  wrapper. The tool updates explicit graph state through commands; the
  middleware prevents conflicting parallel TODO writes from one model response.
  """

  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.Middleware.Helpers
  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Agent.State
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph
  alias BeamWeaver.Tools.Todo

  @default_tool_name "write_todos"
  @default_tool_description Todo.default_description()
  @default_system_prompt """
  ## `write_todos`

  You have access to the `write_todos` tool to help you manage and plan complex objectives.
  Use this tool for complex objectives to ensure that you are tracking each necessary step and giving the user visibility into your progress.
  This tool is very helpful for planning complex objectives, and for breaking down these larger complex objectives into smaller steps.

  It is critical that you mark todos as completed as soon as you are done with a step. Do not batch up multiple steps before marking them as completed.
  For simple objectives that only require a few steps, it is better to just complete the objective directly and NOT use this tool.
  Writing todos takes time and tokens, use it when it is helpful for managing complex many-step problems! But not for simple few-step requests.

  ## Important To-Do List Usage Notes to Remember

  - The `write_todos` tool should never be called multiple times in parallel.
  - Don't be afraid to revise the To-Do list as you go. New information may reveal new tasks that need to be done, or old tasks that are irrelevant.
  """

  @parallel_error """
  Error: The `write_todos` tool should never be called multiple times in parallel. \
  Please call it only once per model invocation to update the todo list.
  """

  defstruct state_key: :todos,
            tool_name: @default_tool_name,
            tool_description: @default_tool_description,
            system_prompt: @default_system_prompt

  def new(opts \\ []) do
    %__MODULE__{
      state_key: Keyword.get(opts, :state_key, :todos),
      tool_name: Keyword.get(opts, :tool_name, @default_tool_name),
      tool_description: Keyword.get(opts, :tool_description, @default_tool_description),
      system_prompt: Keyword.get(opts, :system_prompt, @default_system_prompt)
    }
  end

  @impl true
  def name(%__MODULE__{state_key: :todos}), do: :todo_list
  def name(%__MODULE__{state_key: state_key}), do: :"todo_list:#{state_key}"

  @impl true
  def state_schema(%__MODULE__{state_key: state_key}) do
    %{state_key => Graph.channel(BeamWeaver.Graph.Channels.LastValue)}
  end

  @impl true
  def tools(%__MODULE__{} = middleware) do
    [
      Todo.new(
        state_key: middleware.state_key,
        name: middleware.tool_name,
        description: middleware.tool_description
      )
    ]
  end

  def wrap_model_call(%__MODULE__{} = middleware, %ModelRequest{} = request, handler) do
    request
    |> ModelRequest.override(system_message: Helpers.append_prompt(request.system_message, middleware.system_prompt))
    |> handler.()
  end

  def after_model(%__MODULE__{} = middleware, state, _runtime) do
    state
    |> State.messages()
    |> latest_assistant()
    |> parallel_todo_error(middleware)
  end

  defp parallel_todo_error(nil, _middleware), do: nil

  defp parallel_todo_error(%Message{tool_calls: calls}, %__MODULE__{} = middleware)
       when is_list(calls) do
    todo_calls = Enum.filter(calls, &(tool_name(&1) == middleware.tool_name))

    if length(todo_calls) > 1 do
      %{messages: Enum.map(todo_calls, &error_message/1)}
    end
  end

  defp parallel_todo_error(_message, _middleware), do: nil

  defp error_message(call) do
    Message.tool(String.trim(@parallel_error),
      tool_call_id: tool_call_id(call),
      name: tool_name(call),
      metadata: %{status: "error", error_type: :parallel_todo_writes}
    )
  end

  defp latest_assistant(messages) do
    Enum.find(Enum.reverse(messages), &match?(%Message{role: :assistant}, &1))
  end

  defp tool_name(call), do: Map.get(call, :name)

  defp tool_call_id(call) do
    Map.get(call, :id) ||
      Map.get(call, :tool_call_id)
  end
end
