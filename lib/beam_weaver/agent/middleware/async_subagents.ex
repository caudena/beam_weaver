defmodule BeamWeaver.Agent.Middleware.AsyncSubagents do
  @moduledoc """
  Starts, checks, updates and cancels application-owned asynchronous tasks.

  Task metadata is kept in graph state; the configured client owns remote
  scheduling, persistence and cancellation. A stored task ID is not proof of
  completion. Refresh status before presenting a result.

  It adds nothing to the system prompt unless given `system_prompt:`, which
  adds that text followed by the list of async subagents.

  Every client call gets `parent:` in its opts, which says which agent, thread
  and tool call made it; see `t:BeamWeaver.Agent.Protocol.Client.parent/0`.
  """

  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.Protocol.Client
  alias BeamWeaver.Agent.Subagent.AsyncSpec
  alias BeamWeaver.Agent.Subagent.AsyncTask
  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Core.ToolRuntime
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.MapShape
  alias BeamWeaver.Tracing

  import BeamWeaver.Agent.Subagent.Helpers,
    only: [agent_names: 1, available_agents: 1, value: 2, value: 3, with_agents_prompt: 3]

  # Listing skips these. `interrupted` isn't one: a person can resume the run
  # on the server, and it runs on.
  @terminal_statuses ~w(cancelled success error timeout complete completed)

  # Each tool offers only the arguments it reads.
  @arguments %{
    "task_id" => %{"type" => "string"},
    "subagent_type" => %{"type" => "string"},
    "description" => %{"type" => "string"},
    "message" => %{"type" => "string"},
    "status_filter" => %{
      "type" => "string",
      "enum" => ["running", "success", "error", "cancelled", "all"]
    }
  }

  # A status in the conversation was true when it was fetched; the task may
  # have moved on since.
  @stale_status_note "A status from an earlier call may be out of date, so call this tool again rather than repeating it."

  defstruct subagents: [], system_prompt: nil

  def new(opts \\ []) do
    subagents = opts |> Keyword.get(:subagents, []) |> List.wrap() |> Enum.map(&normalize/1)
    validate_unique_names!(subagents)
    validate_clients!(subagents)

    %__MODULE__{subagents: subagents, system_prompt: Keyword.get(opts, :system_prompt)}
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
        {["subagent_type", "description"], []},
        fn input -> start_task(middleware, input) end
      ),
      async_tool(
        "check_async_task",
        "Check asynchronous task status. " <> @stale_status_note,
        {["task_id"], []},
        fn input -> check_task(middleware, input) end
      ),
      async_tool(
        "update_async_task",
        "Append an update to an asynchronous task.",
        {["task_id", "message"], []},
        fn input -> update_task(middleware, input) end
      ),
      async_tool("cancel_async_task", "Cancel an asynchronous task.", {["task_id"], []}, fn input ->
        cancel_task(middleware, input)
      end),
      async_tool(
        "list_async_tasks",
        "List known asynchronous tasks with live statuses. " <> @stale_status_note,
        {[], ["status_filter"]},
        fn input -> list_tasks(middleware, input) end
      )
    ]
  end

  @impl true
  def wrap_model_call(%__MODULE__{} = middleware, request, handler),
    do: handler.(with_agents_prompt(request, middleware, "Available async subagent types"))

  # A spec written as a struct gets its client from its `url:` as one built
  # with `AsyncSpec.new/1` does.
  defp normalize(%AsyncSpec{} = subagent), do: subagent |> Map.from_struct() |> AsyncSpec.new()
  defp normalize(opts), do: AsyncSpec.new(opts)

  defp validate_unique_names!(subagents) do
    duplicates = for {name, count} <- Enum.frequencies_by(subagents, & &1.name), count > 1, do: name

    if duplicates != [] do
      raise ArgumentError, "duplicate async subagent names: #{Enum.join(duplicates, ", ")}"
    end
  end

  # Without a client there is no remote run: the task would stay "running"
  # with nothing behind it.
  defp validate_clients!(subagents) do
    case Enum.find(subagents, &is_nil(&1.client)) do
      nil -> :ok
      subagent -> raise ArgumentError, "async subagent #{inspect(subagent.name)} needs a client or a url"
    end
  end

  defp async_tool(name, description, {required, optional}, fun) do
    properties = Map.take(@arguments, required ++ optional)

    Tool.from_function!(
      name: name,
      description: description,
      input_schema: %{"type" => "object", "properties" => properties, "required" => required},
      injected: %{state: :state, tool_call_id: :tool_call_id, tool_runtime: :tool_runtime},
      handler: fn input, _opts -> fun.(input) end,
      metadata: %{integration: :deepagents, kind: :async_subagent}
    )
  end

  defp start_task(%__MODULE__{subagents: subagents}, input) do
    name = value(input, :subagent_type) || value(input, :subagent_name)
    subagent = Enum.find(subagents, &(&1.name == name))

    if is_nil(subagent) do
      "Unknown async subagent type `#{name}`. Available types: #{agent_names(subagents)}"
    else
      description = value(input, :description, "")

      case Client.start_task(
             subagent.client,
             subagent,
             start_payload(subagent, description),
             client_opts(input, subagent)
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
               Client.check_task(subagent.client, subagent, task_id, client_opts(input, subagent)) do
          maybe_task_command(input, "check_async_task", task_id, refresh(task, remote, timestamp()))
        else
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
             {:ok, remote} <-
               Client.update_task(subagent.client, subagent, task_id, update.message, client_opts(input, subagent)) do
          task_command(
            input,
            "update_async_task",
            task_id,
            updated |> Map.put(:status, "running") |> merge_remote(remote)
          )
        else
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
             {:ok, remote} <- Client.cancel_task(subagent.client, subagent, task_id, client_opts(input, subagent)) do
          cancelled = checked |> Map.put(:status, remote_status(remote, "cancelled")) |> merge_remote(remote)
          task_command(input, "cancel_async_task", task_id, cancelled)
        else
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
      Map.new(all_tasks, fn {task_id, task} -> {task_id, live_task(middleware, input, task, now)} end)

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

  # Every client call says which agent made it, so a client can, for example,
  # run the subagent in its parent's sandbox or nest its trace under the
  # parent's.
  defp client_opts(input, %AsyncSpec{name: name}) do
    tool_runtime = value(input, :tool_runtime)

    [
      parent:
        Map.merge(
          %{
            thread_id: parent_thread_id(tool_runtime),
            run_id: parent_run_id(tool_runtime),
            tool_call_id: value(input, :tool_call_id),
            subagent_name: name
          },
          parent_trace(Tracing.capture_context())
        )
    ]
  end

  defp parent_thread_id(%ToolRuntime{config: config}) when is_map(config) do
    case Checkpoint.configurable(config) do
      %{"thread_id" => thread_id} when thread_id not in [nil, ""] -> to_string(thread_id)
      _configurable -> nil
    end
  end

  defp parent_thread_id(_tool_runtime), do: nil

  defp parent_run_id(%ToolRuntime{runtime: %{run_id: run_id}}) when not is_nil(run_id), do: to_string(run_id)
  defp parent_run_id(_tool_runtime), do: nil

  # The tool call's own trace run, which the subagent's trace can nest under.
  defp parent_trace(%Tracing.Context{trace_id: trace_id, run_id: run_id}),
    do: %{trace_id: trace_id, trace_run_id: run_id}

  defp parent_trace(nil), do: %{trace_id: nil, trace_run_id: nil}

  defp task_subagent(%__MODULE__{subagents: subagents}, task) do
    name = value(task, :subagent_name)

    case Enum.find(subagents, &(&1.name == name)) do
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

  defp live_task(%__MODULE__{} = middleware, input, task, now) do
    task_id = value(task, :task_id) || value(task, :id)

    with false <- value(task, :status) in @terminal_statuses,
         {:ok, subagent} <- task_subagent(middleware, task),
         {:ok, remote} <- Client.check_task(subagent.client, subagent, task_id, client_opts(input, subagent)) do
      refresh(task, remote, now)
    else
      _other -> task
    end
  end

  defp filter_tasks(tasks, status_filter) do
    for task <- Map.values(tasks), status_filter in [nil, "", "all"] or value(task, :status) == status_filter, do: task
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
    Start an async subagent on a remote server. The subagent runs in the background and returns a task ID immediately; the other async task tools take that ID. Give the user the full task ID and stop: check on the task only when the user asks, never in a loop.

    Available async agent types:
    #{available_agents(subagents)}
    """
  end

  defp timestamp,
    do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp encode_task(task), do: task |> Map.from_struct() |> BeamWeaver.JSON.encode!()
end
