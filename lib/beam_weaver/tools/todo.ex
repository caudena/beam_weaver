defmodule BeamWeaver.Tools.Todo do
  @moduledoc """
  State tool that updates explicit agent state through graph commands.
  """

  @behaviour BeamWeaver.Core.Tool
  @behaviour BeamWeaver.ToolKit

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph.Command

  @description """
  Use this tool to create and manage a structured task list for your current work session. This helps you track progress, organize complex tasks, and demonstrate thoroughness to the user.

  Only use this tool if you think it will be helpful in staying organized. If the user's request is trivial and takes less than 3 steps, it is better to NOT use this tool and just do the task directly.

  ## When to Use This Tool

  Use this tool in these scenarios:

  1. Complex multi-step tasks - When a task requires 3 or more distinct steps or actions
  2. Non-trivial and complex tasks - Tasks that require careful planning or multiple operations
  3. User explicitly requests todo list - When the user directly asks you to use the todo list
  4. User provides multiple tasks - When users provide a list of things to be done (numbered or comma-separated)
  5. The plan may need future revisions or updates based on results from the first few steps

  ## How to Use This Tool

  1. When you start working on a task - Mark it as in_progress BEFORE beginning work.
  2. After completing a task - Mark it as completed and add any new follow-up tasks discovered during implementation.
  3. You can also update future tasks, such as deleting them if they are no longer necessary, or adding new tasks that are necessary. Don't change previously completed tasks.
  4. You can make several updates to the todo list at once. For example, when you complete a task, you can mark the next task you need to start as in_progress.

  ## When NOT to Use This Tool

  It is important to skip using this tool when:
  1. There is only a single, straightforward task
  2. The task is trivial and tracking it provides no benefit
  3. The task can be completed in less than 3 trivial steps
  4. The task is purely conversational or informational

  ## Task States and Management

  1. **Task States**: Use these states to track progress:
      - pending: Task not yet started
      - in_progress: Currently working on (you can have multiple tasks in_progress at a time if they are not related to each other and can be run in parallel)
      - completed: Task finished successfully

  2. **Task Management**:
      - Update task status in real-time as you work
      - Mark tasks complete IMMEDIATELY after finishing (don't batch completions)
      - Complete current tasks before starting new ones
      - Remove tasks that are no longer relevant from the list entirely
      - IMPORTANT: When you write this todo list, you should mark your first task (or tasks) as in_progress immediately!.
      - IMPORTANT: Unless all tasks are completed, you should always have at least one task in_progress to show the user that you are working on something.

  3. **Task Completion Requirements**:
      - ONLY mark a task as completed when you have FULLY accomplished it
      - If you encounter errors, blockers, or cannot finish, keep the task as in_progress
      - When blocked, create a new task describing what needs to be resolved
      - Never mark a task as completed if:
          - There are unresolved issues or errors
          - Work is partial or incomplete
          - You encountered blockers that prevent completion
          - You couldn't find necessary resources or dependencies
          - Quality standards haven't been met

  4. **Task Breakdown**:
      - Create specific, actionable items
      - Break complex tasks into smaller, manageable steps
      - Use clear, descriptive task names

  Being proactive with task management demonstrates attentiveness and ensures you complete all requirements successfully
  Remember: If you only need to make a few tool calls to complete a task, and it is clear what you need to do, it is better to just do the task directly and NOT call this tool at all.
  """

  defstruct state_key: :todos,
            name: "write_todos",
            description: @description

  def new(opts \\ []) do
    %__MODULE__{
      state_key: Keyword.get(opts, :state_key, :todos),
      name: Keyword.get(opts, :name, "write_todos"),
      description: Keyword.get(opts, :description, @description)
    }
  end

  def default_description, do: @description

  @impl BeamWeaver.ToolKit
  def tools(opts \\ []), do: [new(opts)]

  @impl true
  def name(%__MODULE__{name: name}), do: name

  @impl true
  def description(%__MODULE__{description: description}), do: description

  @impl true
  def input_schema(_tool) do
    %{
      "type" => "object",
      "properties" => %{
        "todos" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "content" => %{"type" => "string", "description" => "The content/description of the todo item."},
              "status" => %{
                "type" => "string",
                "enum" => ["pending", "in_progress", "completed"],
                "description" => "The current status of the todo item."
              }
            },
            "required" => ["content", "status"],
            "additionalProperties" => false
          }
        }
      },
      "required" => ["todos"],
      "additionalProperties" => false
    }
  end

  @impl true
  def injected(_tool), do: %{state: :state, tool_call_id: :tool_call_id}

  @impl true
  def return_direct(_tool), do: false

  @impl true
  def response_format(_tool), do: nil

  @impl true
  def output_schema(_tool), do: %{"type" => "object"}

  @impl true
  def tags(_tool), do: [:todo]

  @impl true
  def metadata(_tool), do: %{}

  @impl true
  def provider_opts(_tool), do: %{}

  @impl true
  def invoke(%__MODULE__{} = tool, input, _opts) do
    state = Map.get(input, :state) || Map.get(input, "state") || %{}
    call_id = Map.get(input, :tool_call_id) || Map.get(input, "tool_call_id")
    todos = Map.get(state, tool.state_key, Map.get(state, to_string(tool.state_key), [])) || []

    with {:ok, todos, _result} <- apply_todos(todos, input) do
      message =
        Message.tool("Updated todo list to #{inspect_todos(todos)}",
          tool_call_id: call_id,
          name: name(tool),
          metadata: %{status: "success"}
        )

      {:ok, %Command{update: %{tool.state_key => todos, messages: [message]}}}
    end
  end

  defp apply_todos(_current, input) do
    case get_value(input, :todos, :missing) do
      :missing -> {:error, Error.new(:invalid_todos, "write_todos input must include a todos array")}
      todos -> replace_todos(todos)
    end
  end

  defp replace_todos(todos) when is_list(todos) do
    normalized =
      todos
      |> Enum.map(&normalize_todo/1)
      |> Enum.reject(&is_nil/1)

    if length(normalized) == length(todos) do
      {:ok, normalized, %{todos: normalized}}
    else
      {:error, Error.new(:invalid_todo, "each todo must include non-empty content and a valid status")}
    end
  end

  defp replace_todos(_todos),
    do: {:error, Error.new(:invalid_todos, "todos must be an array of todo items")}

  defp normalize_todo(%{} = todo) do
    content = get_value(todo, :content)
    status = todo |> get_value(:status) |> normalize_status()

    if is_binary(content) and String.trim(content) != "" and status do
      %{content: String.trim(content), status: status}
    end
  end

  defp normalize_todo(_todo), do: nil

  defp normalize_status(nil), do: nil
  defp normalize_status(status) when status in ["pending", "in_progress", "completed"], do: status

  defp normalize_status(status) when is_atom(status),
    do: status |> Atom.to_string() |> normalize_status()

  defp normalize_status(_status), do: nil

  defp inspect_todos(todos) do
    inspect(todos, charlists: :as_lists)
  end

  defp get_value(map, key, default \\ nil)
  defp get_value(map, key, default) when is_map(map), do: Map.get(map, key, Map.get(map, to_string(key), default))
  defp get_value(_map, _key, default), do: default
end
