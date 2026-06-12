defmodule BeamWeaver.Agent.Middleware.AsyncSubagents do
  @moduledoc """
  Minimal Agent Protocol async-subagent tool surface.

  The first implementation keeps task metadata in graph state and is designed
  so an HTTP client adapter can be plugged in without changing the agent-facing
  tools.
  """

  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Agent.Protocol.Client
  alias BeamWeaver.Agent.Subagent.AsyncSpec
  alias BeamWeaver.Agent.Subagent.AsyncTask
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Command

  import BeamWeaver.Agent.Subagent.Helpers,
    only: [append_prompt: 2, available_agents: 1, value: 2, value: 3]

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

  @impl true
  def state_schema(_middleware) do
    %{async_tasks: Graph.channel(BeamWeaver.Graph.Channels.LastValue)}
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
  defp normalize(map) when is_map(map), do: AsyncSpec.new(map)
  defp normalize(opts) when is_list(opts), do: AsyncSpec.new(opts)

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

          tasks = tasks(input)
          now = timestamp()

          task =
            AsyncTask.new(%{
              id: task_id,
              task_id: task_id,
              subagent_name: name,
              graph_id: subagent.graph_id,
              url: subagent.url,
              thread_id: BeamWeaver.MapAccess.get(remote, :thread_id) || task_id,
              run_id:
                BeamWeaver.MapAccess.get(remote, :run_id) ||
                  BeamWeaver.MapAccess.get(remote, :id) || task_id,
              status: remote_status(remote, "running"),
              created_at: now,
              last_checked_at: now,
              last_updated_at: now,
              description: description,
              remote: remote,
              updates: []
            })

          task_command(input, "start_async_task", Map.put(tasks, task_id, task), task)

        {:error, reason} ->
          "Async subagent error: #{format_error(reason)}"
      end
    end
  end

  defp check_task(%__MODULE__{} = middleware, input) do
    task_id = value(input, :task_id)
    now = timestamp()

    case Map.fetch(tasks(input), task_id) do
      {:ok, task} ->
        with {:ok, subagent} <- task_subagent(middleware, task),
             {:ok, remote} <-
               Client.check_task(subagent.client, subagent, task_id, []) do
          task =
            task
            |> merge_remote(remote)
            |> Map.put(:last_checked_at, now)
            |> maybe_touch_updated_at(task, now)

          maybe_task_command(
            input,
            "check_async_task",
            Map.put(tasks(input), task_id, task),
            task
          )
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
    tasks = tasks(input)
    now = timestamp()

    case Map.fetch(tasks, task_id) do
      {:ok, task} ->
        update = %{
          message: value(input, :message, ""),
          created_at: now
        }

        with {:ok, subagent} <- task_subagent(middleware, task),
             {:ok, remote} <-
               Client.update_task(
                 subagent.client,
                 subagent,
                 task_id,
                 update.message,
                 []
               ) do
          task =
            task
            |> Map.update(:updates, [update], &(&1 ++ [update]))
            |> Map.put(:status, "running")
            |> Map.put(:last_updated_at, now)
            |> merge_remote(remote)

          task_command(input, "update_async_task", Map.put(tasks, task_id, task), task)
        else
          :no_remote_client ->
            task =
              task
              |> Map.update(:updates, [update], &(&1 ++ [update]))
              |> Map.put(:last_updated_at, now)

            task_command(input, "update_async_task", Map.put(tasks, task_id, task), task)

          {:error, :unknown_subagent} ->
            "Unknown async subagent: #{task_value(task, :subagent_name)}"

          {:error, reason} ->
            "Async subagent error: #{format_error(reason)}"
        end

      :error ->
        "Unknown async task: #{task_id}"
    end
  end

  defp cancel_task(%__MODULE__{} = middleware, input) do
    task_id = value(input, :task_id)
    tasks = tasks(input)
    now = timestamp()

    case Map.fetch(tasks, task_id) do
      {:ok, task} ->
        with {:ok, subagent} <- task_subagent(middleware, task),
             {:ok, remote} <-
               Client.cancel_task(subagent.client, subagent, task_id, []) do
          task =
            task
            |> Map.put(:status, remote_status(remote, "cancelled"))
            |> Map.put(:last_checked_at, now)
            |> Map.put(:last_updated_at, now)
            |> merge_remote(remote)

          task_command(input, "cancel_async_task", Map.put(tasks, task_id, task), task)
        else
          :no_remote_client ->
            task =
              task
              |> Map.put(:status, "cancelled")
              |> Map.put(:last_checked_at, now)
              |> Map.put(:last_updated_at, now)

            task_command(input, "cancel_async_task", Map.put(tasks, task_id, task), task)

          {:error, :unknown_subagent} ->
            "Unknown async subagent: #{task_value(task, :subagent_name)}"

          {:error, reason} ->
            "Async subagent error: #{format_error(reason)}"
        end

      :error ->
        "Unknown async task: #{task_id}"
    end
  end

  defp list_tasks(%__MODULE__{} = middleware, input) do
    all_tasks = tasks(input)
    filtered = filter_tasks(all_tasks, value(input, :status_filter, "all"))

    if filtered == [] do
      "No async subagent tasks tracked."
    else
      now = timestamp()

      {updated, entries} =
        Enum.reduce(filtered, {%{}, []}, fn task, {tasks_acc, entries} ->
          live_task = live_task(middleware, task, now)
          task_id = task_value(live_task, :task_id) || task_value(live_task, :id)

          {
            Map.put(tasks_acc, task_id, live_task),
            [
              "- task_id: #{task_id}  subagent: #{task_value(live_task, :subagent_name)}  status: #{task_value(live_task, :status)}"
              | entries
            ]
          }
        end)

      message =
        "#{map_size(updated)} tracked task(s):\n" <>
          (entries |> Enum.reverse() |> Enum.join("\n"))

      case value(input, :tool_call_id) do
        id when is_binary(id) and id != "" ->
          %Command{
            update: %{
              async_tasks: Map.merge(all_tasks, updated),
              messages: [Message.tool(message, tool_call_id: id, name: "list_async_tasks")]
            }
          }

        _other ->
          updated
          |> Map.values()
          |> Enum.map(&AsyncTask.to_map/1)
          |> BeamWeaver.JSON.encode!()
      end
    end
  end

  defp task_command(input, tool_name, tasks, task) do
    message =
      Message.tool(encode_task(task),
        tool_call_id: value(input, :tool_call_id),
        name: tool_name
      )

    %Command{update: %{async_tasks: tasks, messages: [message]}}
  end

  defp maybe_task_command(input, tool_name, tasks, task) do
    case value(input, :tool_call_id) do
      id when is_binary(id) and id != "" -> task_command(input, tool_name, tasks, task)
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
    name = task_value(task, :subagent_name)

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
    |> Map.put(:status, remote_status(remote, task_value(task, :status) || "running"))
    |> maybe_put_remote_result(remote)
    |> maybe_put_remote(:run_id, remote)
    |> maybe_put_remote(:thread_id, remote)
  end

  defp maybe_put_remote_result(task, remote) do
    case remote_result(remote) do
      nil -> task
      result -> Map.put(task, :result, result)
    end
  end

  defp maybe_put_remote(task, key, remote) do
    case BeamWeaver.MapAccess.get(remote, key) do
      nil -> task
      value -> Map.put(task, key, value)
    end
  end

  defp maybe_touch_updated_at(task, previous, now) do
    if task_value(task, :status) != task_value(previous, :status) do
      Map.put(task, :last_updated_at, now)
    else
      task
    end
  end

  defp live_task(%__MODULE__{} = middleware, task, now) do
    status = task_value(task, :status)

    if status in @terminal_statuses do
      task
    else
      case task_subagent(middleware, task) do
        {:ok, subagent} ->
          case Client.check_task(
                 subagent.client,
                 subagent,
                 task_value(task, :task_id) || task_value(task, :id),
                 []
               ) do
            {:ok, remote} ->
              task
              |> merge_remote(remote)
              |> Map.put(:last_checked_at, now)
              |> maybe_touch_updated_at(task, now)

            _error ->
              task
          end

        _missing ->
          task
      end
    end
  end

  defp filter_tasks(tasks, status_filter) when status_filter in [nil, "", "all"],
    do: Map.values(tasks)

  defp filter_tasks(tasks, status_filter) do
    tasks
    |> Map.values()
    |> Enum.filter(&(task_value(&1, :status) == status_filter))
  end

  defp remote_id(remote) when is_map(remote),
    do:
      BeamWeaver.MapAccess.get(remote, :thread_id) ||
        BeamWeaver.MapAccess.get(remote, :task_id) ||
        BeamWeaver.MapAccess.get(remote, :id) ||
        BeamWeaver.MapAccess.get(remote, :run_id)

  defp remote_id(_remote), do: nil

  defp remote_status(remote, default) when is_map(remote),
    do: BeamWeaver.MapAccess.get(remote, :status) || default

  defp remote_status(_remote, default), do: default

  defp remote_result(remote) do
    BeamWeaver.MapAccess.get(remote, :result) || remote_messages_result(remote)
  end

  defp remote_messages_result(remote) do
    values = BeamWeaver.MapAccess.get(remote, :values) || remote
    messages = BeamWeaver.MapAccess.get(values, :messages) || []

    messages
    |> List.wrap()
    |> Enum.reverse()
    |> Enum.find_value(&message_content/1)
  end

  defp message_content(message) when is_map(message) do
    case BeamWeaver.MapAccess.get(message, :content) || BeamWeaver.MapAccess.get(message, :text) do
      content when is_binary(content) and content != "" -> content
      content when is_list(content) -> Enum.map_join(content, "", &message_content/1)
      _empty -> nil
    end
  end

  defp message_content(content) when is_binary(content) and content != "", do: content
  defp message_content(_message), do: nil

  defp task_value(task, key) when is_map(task), do: BeamWeaver.MapAccess.get(task, key)
  defp task_value(_task, _key), do: nil

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

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

  defp encode_task(task), do: task |> AsyncTask.to_map() |> BeamWeaver.JSON.encode!()
end
