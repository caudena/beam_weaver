defmodule BeamWeaver.Agent.Middleware.ToolCallLimit do
  @moduledoc """
  Tracks tool-call counts and satisfies over-limit calls with tagged messages.
  """

  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.State
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph

  defstruct tool_name: nil,
            thread_limit: 10,
            run_limit: nil,
            exit_behavior: :continue,
            message: "Tool call limit exceeded"

  def new(opts \\ []) do
    %__MODULE__{
      tool_name: Keyword.get(opts, :tool_name),
      thread_limit: Keyword.get(opts, :thread_limit, Keyword.get(opts, :max_calls, 10)),
      run_limit: Keyword.get(opts, :run_limit),
      exit_behavior: opts |> Keyword.get(:exit_behavior, :continue) |> normalize_exit_behavior(),
      message: Keyword.get(opts, :message, "Tool call limit exceeded")
    }
    |> validate!()
  end

  @impl true
  def name(%__MODULE__{tool_name: nil}), do: :tool_call_limit
  def name(%__MODULE__{tool_name: tool_name}), do: :"tool_call_limit:#{tool_name}"

  @impl true
  def state_schema(_middleware) do
    %{
      thread_tool_call_count: Graph.private_channel(BeamWeaver.Graph.Channels.LastValue),
      run_tool_call_count: Graph.private_channel(BeamWeaver.Graph.Channels.UntrackedValue)
    }
  end

  @impl true
  def can_jump_to(_middleware, :after_model), do: [:end]
  def can_jump_to(_middleware, _hook), do: []

  def after_model(%__MODULE__{} = middleware, state, _runtime) do
    messages = State.messages(state)

    case latest_assistant(messages) do
      %Message{tool_calls: calls} when is_list(calls) and calls != [] ->
        check_calls(middleware, state, calls)

      _other ->
        nil
    end
  end

  defp check_calls(%__MODULE__{} = middleware, state, calls) do
    key = count_key(middleware)
    thread_counts = count_map(state, :thread_tool_call_count)
    run_counts = count_map(state, :run_tool_call_count)
    thread_count = Map.get(thread_counts, key, 0)
    run_count = Map.get(run_counts, key, 0)

    {allowed, blocked, next_thread_count, next_run_count} =
      separate_calls(middleware, calls, thread_count, run_count)

    cond do
      allowed == [] and blocked == [] ->
        nil

      blocked == [] ->
        %{
          thread_tool_call_count: Map.put(thread_counts, key, next_thread_count),
          run_tool_call_count: Map.put(run_counts, key, next_run_count)
        }

      middleware.exit_behavior == :error ->
        {:error,
         Error.new(:tool_call_limit_exceeded, final_message(middleware, blocked, state), %{
           tool_name: middleware.tool_name,
           thread_count: next_thread_count + length(blocked),
           run_count: next_run_count + length(blocked),
           thread_limit: middleware.thread_limit,
           run_limit: middleware.run_limit
         })}

      middleware.exit_behavior == :end ->
        end_update(
          middleware,
          state,
          thread_counts,
          run_counts,
          key,
          next_thread_count,
          next_run_count,
          blocked,
          calls
        )

      true ->
        %{
          thread_tool_call_count: Map.put(thread_counts, key, next_thread_count),
          run_tool_call_count: Map.put(run_counts, key, next_run_count + length(blocked)),
          messages: Enum.map(blocked, &limit_message(&1, middleware))
        }
    end
  end

  defp separate_calls(%__MODULE__{} = middleware, calls, thread_count, run_count) do
    Enum.reduce(calls, {[], [], thread_count, run_count}, fn call, {allowed, blocked, thread_acc, run_acc} ->
      cond do
        not matches_tool?(middleware, call) ->
          {allowed, blocked, thread_acc, run_acc}

        would_exceed?(middleware, thread_acc, run_acc) ->
          {allowed, blocked ++ [call], thread_acc, run_acc}

        true ->
          {allowed ++ [call], blocked, thread_acc + 1, run_acc + 1}
      end
    end)
  end

  defp end_update(
         %__MODULE__{} = middleware,
         state,
         thread_counts,
         run_counts,
         key,
         next_thread_count,
         next_run_count,
         blocked,
         calls
       ) do
    other_pending =
      Enum.filter(calls, fn call ->
        middleware.tool_name && not matches_tool?(middleware, call)
      end)

    if other_pending != [] do
      {:error,
       Error.new(
         :tool_call_limit_parallel_end_unsupported,
         "cannot end execution with other tool calls pending",
         %{tools: Enum.map(other_pending, &tool_name/1)}
       )}
    else
      run_count = next_run_count + length(blocked)

      %{
        thread_tool_call_count: Map.put(thread_counts, key, next_thread_count),
        run_tool_call_count: Map.put(run_counts, key, run_count),
        jump_to: :end,
        messages:
          Enum.map(blocked, &limit_message(&1, middleware)) ++
            [Message.assistant(final_message(middleware, blocked, state))]
      }
    end
  end

  defp limit_message(call, %__MODULE__{} = middleware) do
    Message.tool(tool_message_content(middleware),
      tool_call_id: tool_call_id(call),
      name: tool_name(call),
      metadata: %{
        status: "error",
        error_type: :tool_call_limit_exceeded,
        tool_name: middleware.tool_name,
        thread_limit: middleware.thread_limit,
        run_limit: middleware.run_limit
      }
    )
  end

  defp final_message(%__MODULE__{} = middleware, blocked, state) do
    key = count_key(middleware)
    thread_counts = count_map(state, :thread_tool_call_count)
    run_counts = count_map(state, :run_tool_call_count)
    thread_count = Map.get(thread_counts, key, 0) + length(blocked)
    run_count = Map.get(run_counts, key, 0) + length(blocked)

    tool_desc = if middleware.tool_name, do: "'#{middleware.tool_name}' tool", else: "Tool"

    exceeded =
      [
        final_limit_fragment(:thread, thread_count, middleware.thread_limit),
        final_limit_fragment(:run, run_count, middleware.run_limit)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" and ")

    "#{tool_desc} call limit reached: #{exceeded}."
  end

  defp tool_message_content(%__MODULE__{tool_name: nil, message: message})
       when message == "Tool call limit exceeded",
       do: "Tool call limit exceeded. Do not make additional tool calls."

  defp tool_message_content(%__MODULE__{tool_name: tool_name, message: message})
       when message == "Tool call limit exceeded",
       do: "Tool call limit exceeded. Do not call '#{tool_name}' again."

  defp tool_message_content(%__MODULE__{message: message}), do: message

  defp final_limit_fragment(_scope, _count, nil), do: nil

  defp final_limit_fragment(scope, count, limit) when count > limit,
    do: "#{scope} limit exceeded (#{count}/#{limit} calls)"

  defp final_limit_fragment(_scope, _count, _limit), do: nil

  defp validate!(%__MODULE__{thread_limit: nil, run_limit: nil}) do
    raise ArgumentError, "at least one tool call limit must be configured"
  end

  defp validate!(%__MODULE__{thread_limit: thread_limit, run_limit: run_limit} = middleware) do
    unless valid_limit?(thread_limit) and valid_limit?(run_limit) do
      raise ArgumentError, "tool call limits must be nil or non-negative integers"
    end

    if is_integer(thread_limit) and is_integer(run_limit) and run_limit > thread_limit do
      raise ArgumentError, "run_limit cannot exceed thread_limit"
    end

    middleware
  end

  defp valid_limit?(nil), do: true
  defp valid_limit?(limit), do: is_integer(limit) and limit >= 0

  defp normalize_exit_behavior(value) when value in [:continue, "continue"], do: :continue
  defp normalize_exit_behavior(value) when value in [:error, "error"], do: :error
  defp normalize_exit_behavior(value) when value in [:end, "end"], do: :end

  defp normalize_exit_behavior(value) do
    raise ArgumentError, "invalid tool call limit exit_behavior: #{inspect(value)}"
  end

  defp matches_tool?(%__MODULE__{tool_name: nil}, _call), do: true
  defp matches_tool?(%__MODULE__{tool_name: name}, call), do: tool_name(call) == name

  defp would_exceed?(%__MODULE__{} = middleware, thread_count, run_count) do
    would_exceed?(thread_count, middleware.thread_limit) or
      would_exceed?(run_count, middleware.run_limit)
  end

  defp would_exceed?(_count, nil), do: false
  defp would_exceed?(count, limit), do: count + 1 > limit

  defp count_key(%__MODULE__{tool_name: nil}), do: "__all__"
  defp count_key(%__MODULE__{tool_name: tool_name}), do: to_string(tool_name)

  defp count_map(state, key) do
    case Map.get(state, key, %{}) do
      value when is_map(value) -> stringify_keys(value)
      _other -> %{}
    end
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp latest_assistant(messages) do
    Enum.find(Enum.reverse(messages), &match?(%Message{role: :assistant}, &1))
  end

  defp tool_call_id(call),
    do:
      Map.get(call, :id) ||
        Map.get(call, :tool_call_id) ||
        Map.get(call, :call_id)

  defp tool_name(call), do: Map.get(call, :name)
end
