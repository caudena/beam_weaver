defmodule BeamWeaver.Agent.Middleware.AsyncSubagents do
  @moduledoc """
  Minimal Agent Protocol async-subagent tool surface.

  The first implementation keeps task metadata in graph state and is designed
  so an HTTP client adapter can be plugged in without changing the agent-facing
  tools.
  """

  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Agent.Protocol.Client
  alias BeamWeaver.Agent.Subagent.AsyncSpec
  alias BeamWeaver.Agent.Subagent.AsyncTask
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.MapShape

  import BeamWeaver.Agent.Middleware.Helpers, only: [append_prompt: 2]
  import BeamWeaver.Agent.Subagent.Helpers, only: [available_agents: 1, value: 2, value: 3]

  @async_task_system_prompt """
  ## Async subagents

  You have access to async subagent tools that launch background tasks on remote Agent Protocol servers.

  Use `start_async_task` to launch work and then return control to the user. Use `check_async_task`, `update_async_task`, `cancel_async_task`, and `list_async_tasks` only when the user asks for those follow-up actions.

  Never poll task status in a loop. Always show the full task_id.
  """

  @terminal_statuses ~w(cancelled success error timeout interrupted complete completed)

  defstruct subagents: [], system_prompt: @async_task_system_prompt

  def new(opts \\ []) do
    subagents = opts |> Keyword.get(:subagents, []) |> List.wrap() |> Enum.map(&normalize/1)
    validate_unique_names!(subagents)

    %__MODULE__{
      subagents: subagents,
      system_prompt: Keyword.get(opts, :system_prompt) || @async_task_system_prompt
    }
  end

  @impl true
  def name(_middleware), do: :deepagents_async_subagents

  # Each task tool writes only the tasks it changed, and the writes merge, so
  # parallel calls on different tasks keep every change.
  @impl true
  def state_schema(_middleware) do
    %{
      async_tasks:
        Graph.channel({BeamWeaver.Graph.Channels.BinaryOperatorAggregate, &Map.merge/2},
          initial: %{}
        )
    }
  end

  @impl true
  def tools(%__MODULE__{} = middleware) do
    [
      async_tool(
        "start_async_task",
        start_description(middleware.subagents),
        ["description"],
        fn input -> start_task(middleware, input) end
      ),
      async_tool("check_async_task", "Check asynchronous task status.", ["task_id"], fn input ->
        check_task(middleware, input)
      end),
      async_tool(
        "update_async_task",
        "Append an update to an asynchronous task.",
        ["task_id", "message"],
        fn input -> update_task(middleware, input) end
      ),
      async_tool("cancel_async_task", "Cancel an asynchronous task.", ["task_id"], fn input ->
        cancel_task(middleware, input)
      end),
      async_tool(
        "list_async_tasks",
        "List known asynchronous tasks with live statuses.",
        [],
        fn input ->
          list_tasks(middleware, input)
        end
      )
    ]
  end

  @impl true
  def wrap_model_call(%__MODULE__{system_prompt: nil}, %ModelRequest{} = request, handler),
    do: handler.(request)

  def wrap_model_call(%__MODULE__{} = middleware, %ModelRequest{} = request, handler) do
    prompt =
      middleware.system_prompt <>
        "\n\nAvailable async subagent types:\n\n" <> available_agents(middleware.subagents)

    request
    |> ModelRequest.override(system_message: append_prompt(request.system_message, prompt))
    |> handler.()
  end

  defp normalize(%AsyncSpec{} = subagent), do: subagent
  defp normalize(opts), do: AsyncSpec.new(opts)

  defp validate_unique_names!(subagents) do
    names = Enum.map(subagents, & &1.name)

    duplicates =
      names
      |> Enum.frequencies()
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(fn {name, _count} -> name end)

    if duplicates != [] do
      raise ArgumentError, "duplicate async subagent names: #{Enum.join(duplicates, ", ")}"
    end
  end

  defp async_tool(name, description, required, fun) do
    properties =
      %{
        "task_id" => %{"type" => "string"},
        "subagent_name" => %{"type" => "string"},
        "subagent_type" => %{"type" => "string"},
        "description" => %{"type" => "string"},
        "message" => %{"type" => "string"},
        "status_filter" => %{
          "type" => "string",
          "enum" => ["running", "success", "error", "cancelled", "all"]
        }
      }

    Tool.from_function!(
      name: name,
      description: description,
      input_schema: %{"type" => "object", "properties" => properties, "required" => required},
      injected: %{state: :state, tool_call_id: :tool_call_id},
      handler: fn input, _opts -> fun.(input) end,
      metadata: %{integration: :deepagents, kind: :async_subagent}
    )
  end

  defp start_task(%__MODULE__{subagents: subagents}, input) do
    name = value(input, :subagent_type) || value(input, :subagent_name)
    subagent = Enum.find(subagents, &(&1.name == name))

    if is_nil(subagent) do
      "Unknown async subagent type `#{name}`. Available types: #{available_agent_names(subagents)}"
    else
      description = value(input, :description, "")

      case Client.start_task(
             subagent.client,
             subagent,
             start_payload(subagent, description),
             []
           ) do
        {:ok, remote} ->
          task_id =
            remote_id(remote) ||
              "async-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

          now = timestamp()

          task =
            AsyncTask.new(%{
              id: task_id,
              task_id: task_id,
              subagent_name: name,
              graph_id: subagent.graph_id,
              url: subagent.url,
              thread_id: value(remote, :thread_id) || task_id,
              run_id: value(remote, :run_id) || value(remote, :id) || task_id,
              status: remote_status(remote, "running"),
              created_at: now,
              last_checked_at: now,
              last_updated_at: now,
              description: description,
              remote: remote,
              updates: []
            })

          task_command(input, "start_async_task", task_id, task)

        {:error, reason} ->
          "Async subagent error: #{format_error(reason)}"
      end
    end
  end

  defp check_task(%__MODULE__{} = middleware, input) do
    task_id = value(input, :task_id)

    case Map.fetch(tasks(input), task_id) do
      {:ok, task} ->
        with {:ok, subagent} <- task_subagent(middleware, task),
             {:ok, remote} <-
               Client.check_task(subagent.client, subagent, task_id, []) do
          maybe_task_command(input, "check_async_task", task_id, refresh(task, remote, timestamp()))
        else
          :no_remote_client -> encode_task(task)
          {:error, :unknown_subagent} -> encode_task(task)
          {:error, reason} -> "Async subagent error: #{format_error(reason)}"
        end

      :error ->
        BeamWeaver.JSON.encode!(%{id: task_id, status: "unknown"})
    end
  end

  defp update_task(%__MODULE__{} = middleware, input) do
    task_id = value(input, :task_id)
    now = timestamp()

    case Map.fetch(tasks(input), task_id) do
      {:ok, task} ->
        update = %{message: value(input, :message, ""), created_at: now}
        updated = task |> Map.update(:updates, [update], &(&1 ++ [update])) |> Map.put(:last_updated_at, now)

        with {:ok, subagent} <- task_subagent(middleware, task),
             {:ok, remote} <- Client.update_task(subagent.client, subagent, task_id, update.message, []) do
          task_command(
            input,
            "update_async_task",
            task_id,
            updated |> Map.put(:status, "running") |> merge_remote(remote)
          )
        else
          :no_remote_client -> task_command(input, "update_async_task", task_id, updated)
          {:error, :unknown_subagent} -> "Unknown async subagent: #{value(task, :subagent_name)}"
          {:error, reason} -> "Async subagent error: #{format_error(reason)}"
        end

      :error ->
        "Unknown async task: #{task_id}"
    end
  end

  defp cancel_task(%__MODULE__{} = middleware, input) do
    task_id = value(input, :task_id)
    now = timestamp()

    case Map.fetch(tasks(input), task_id) do
      {:ok, task} ->
        checked = task |> Map.put(:last_checked_at, now) |> Map.put(:last_updated_at, now)

        with {:ok, subagent} <- task_subagent(middleware, task),
             {:ok, remote} <- Client.cancel_task(subagent.client, subagent, task_id, []) do
          cancelled = checked |> Map.put(:status, remote_status(remote, "cancelled")) |> merge_remote(remote)
          task_command(input, "cancel_async_task", task_id, cancelled)
        else
          :no_remote_client -> task_command(input, "cancel_async_task", task_id, Map.put(checked, :status, "cancelled"))
          {:error, :unknown_subagent} -> "Unknown async subagent: #{value(task, :subagent_name)}"
          {:error, reason} -> "Async subagent error: #{format_error(reason)}"
        end

      :error ->
        "Unknown async task: #{task_id}"
    end
  end

  defp list_tasks(%__MODULE__{} = middleware, input) do
    all_tasks = tasks(input)
    now = timestamp()

    refreshed =
      Map.new(all_tasks, fn {task_id, task} -> {task_id, live_task(middleware, task, now)} end)

    filtered = filter_tasks(refreshed, value(input, :status_filter, "all"))

    if filtered == [] do
      "No async subagent tasks tracked."
    else
      updated = Map.new(filtered, &{value(&1, :task_id) || value(&1, :id), &1})

      entries =
        Enum.map_join(filtered, "\n", fn task ->
          "- task_id: #{value(task, :task_id) || value(task, :id)}  subagent: #{value(task, :subagent_name)}  status: #{value(task, :status)}"
        end)

      message = "#{map_size(updated)} tracked task(s):\n" <> entries

      case value(input, :tool_call_id) do
        id when is_binary(id) and id != "" ->
          %Command{
            update: %{
              # Only the tasks it refreshed, so a parallel call's change to
              # another task stays.
              async_tasks: Map.reject(refreshed, fn {task_id, task} -> all_tasks[task_id] == task end),
              messages: [
                Message.tool(message,
                  tool_call_id: id,
                  name: "list_async_tasks",
                  metadata: %{async_subagents: Enum.map(updated, fn {_id, task} -> task_metadata(task) end)}
                )
              ]
            }
          }

        _other ->
          updated
          |> Map.values()
          |> Enum.map(&Map.from_struct/1)
          |> BeamWeaver.JSON.encode!()
      end
    end
  end

  # Writes only this task, so parallel calls on other tasks keep their changes.
  defp task_command(input, tool_name, task_id, task) do
    message =
      Message.tool(encode_task(task),
        tool_call_id: value(input, :tool_call_id),
        name: tool_name,
        metadata: %{async_subagent: task_metadata(task)}
      )

    %Command{update: %{async_tasks: %{task_id => task}, messages: [message]}}
  end

  defp maybe_task_command(input, tool_name, task_id, task) do
    case value(input, :tool_call_id) do
      id when is_binary(id) and id != "" -> task_command(input, tool_name, task_id, task)
      _other -> encode_task(task)
    end
  end

  defp tasks(input) do
    input
    |> value(:state, %{})
    |> value(:async_tasks, %{})
    |> Kernel.||(%{})
    |> Map.new(fn {task_id, task} -> {to_string(task_id), AsyncTask.new(task)} end)
  end

  defp start_payload(%AsyncSpec{} = subagent, description) do
    %{
      assistant_id: subagent.graph_id,
      input: %{messages: [%{role: "user", content: description}]}
    }
  end

  defp task_subagent(%__MODULE__{subagents: subagents}, task) do
    name = value(task, :subagent_name)

    case Enum.find(subagents, &(&1.name == name)) do
      %AsyncSpec{client: nil} -> :no_remote_client
      %AsyncSpec{} = subagent -> {:ok, subagent}
      nil -> {:error, :unknown_subagent}
    end
  end

  defp merge_remote(task, remote) when remote in [nil, %{}], do: task

  defp merge_remote(task, remote) when is_map(remote) do
    task
    |> Map.put(:remote, remote)
    |> Map.put(:status, remote_status(remote, value(task, :status) || "running"))
    |> MapShape.put_present(:result, remote_result(remote))
    |> MapShape.put_present(:run_id, value(remote, :run_id))
    |> MapShape.put_present(:thread_id, value(remote, :thread_id))
  end

  defp refresh(task, remote, now) do
    checked = task |> merge_remote(remote) |> Map.put(:last_checked_at, now)

    if value(checked, :status) != value(task, :status),
      do: Map.put(checked, :last_updated_at, now),
      else: checked
  end

  defp live_task(%__MODULE__{} = middleware, task, now) do
    with false <- value(task, :status) in @terminal_statuses,
         {:ok, subagent} <- task_subagent(middleware, task),
         {:ok, remote} <- Client.check_task(subagent.client, subagent, value(task, :task_id) || value(task, :id), []) do
      refresh(task, remote, now)
    else
      _other -> task
    end
  end

  defp filter_tasks(tasks, status_filter) when status_filter in [nil, "", "all"],
    do: Map.values(tasks)

  defp filter_tasks(tasks, status_filter) do
    tasks
    |> Map.values()
    |> Enum.filter(&(value(&1, :status) == status_filter))
  end

  defp remote_id(remote),
    do: value(remote, :thread_id) || value(remote, :task_id) || value(remote, :id) || value(remote, :run_id)

  defp remote_status(remote, default), do: value(remote, :status) || default

  defp remote_result(remote) do
    value(remote, :result) || remote_messages_result(remote)
  end

  defp remote_messages_result(remote) do
    values = value(remote, :values) || remote
    messages = value(values, :messages) || []

    messages
    |> List.wrap()
    |> Enum.reverse()
    |> Enum.find_value(&message_content/1)
  end

  defp message_content(message) when is_map(message) do
    case value(message, :content) || value(message, :text) do
      content when is_binary(content) and content != "" -> content
      content when is_list(content) -> Enum.map_join(content, "", &message_content/1)
      _empty -> nil
    end
  end

  defp message_content(content) when is_binary(content) and content != "", do: content
  defp message_content(_message), do: nil

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp task_metadata(task) do
    task
    |> Map.take([:id, :task_id, :subagent_name, :graph_id, :thread_id, :run_id, :status])
    |> MapShape.reject_nil_values()
  end

  defp start_description(subagents) do
    """
    Start an async subagent on a remote server. The subagent runs in the background and returns a task ID immediately.

    Available async agent types:
    #{available_agents(subagents)}
    """
  end

  defp available_agent_names(subagents),
    do: Enum.map_join(subagents, ", ", &"`#{&1.name}`")

  defp timestamp,
    do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp encode_task(task), do: task |> Map.from_struct() |> BeamWeaver.JSON.encode!()
end
