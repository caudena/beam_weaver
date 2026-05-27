defmodule BeamWeaver.Agent.Middleware.ModelCallLimit do
  @moduledoc """
  Tracks model-call counts and enforces thread/run limits.
  """

  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph

  defstruct thread_limit: 10,
            run_limit: nil,
            exit_behavior: :error

  def new(opts \\ []) do
    %__MODULE__{
      thread_limit: Keyword.get(opts, :thread_limit, Keyword.get(opts, :max_calls, 10)),
      run_limit: Keyword.get(opts, :run_limit),
      exit_behavior: opts |> Keyword.get(:exit_behavior, :error) |> normalize_exit_behavior()
    }
    |> validate!()
  end

  @impl true
  def name(_middleware), do: :model_call_limit

  @impl true
  def state_schema(_middleware) do
    %{
      thread_model_call_count: Graph.private_channel(BeamWeaver.Graph.Channels.LastValue),
      run_model_call_count: Graph.private_channel(BeamWeaver.Graph.Channels.UntrackedValue)
    }
  end

  @impl true
  def can_jump_to(_middleware, :before_model), do: [:end]
  def can_jump_to(_middleware, _hook), do: []

  def before_model(%__MODULE__{} = middleware, state, _runtime) do
    thread_count = count(state, :thread_model_call_count)
    run_count = count(state, :run_model_call_count)

    if limit_exceeded?(middleware, thread_count, run_count) do
      message = limit_message(thread_count, run_count, middleware)
      details = limit_details(thread_count, run_count, middleware)

      case middleware.exit_behavior do
        :error ->
          {:error, Error.new(:model_call_limit_exceeded, message, details)}

        :end ->
          %{
            jump_to: :end,
            messages: [
              Message.assistant(message,
                metadata: Map.put(details, :error_type, :model_call_limit_exceeded)
              )
            ]
          }
      end
    end
  end

  def after_model(%__MODULE__{}, state, _runtime) do
    %{
      thread_model_call_count: count(state, :thread_model_call_count) + 1,
      run_model_call_count: count(state, :run_model_call_count) + 1
    }
  end

  defp validate!(%__MODULE__{thread_limit: nil, run_limit: nil}) do
    raise ArgumentError, "at least one model call limit must be configured"
  end

  defp validate!(%__MODULE__{thread_limit: thread_limit, run_limit: run_limit} = middleware) do
    unless valid_limit?(thread_limit) and valid_limit?(run_limit) do
      raise ArgumentError, "model call limits must be nil or non-negative integers"
    end

    middleware
  end

  defp valid_limit?(nil), do: true
  defp valid_limit?(limit), do: is_integer(limit) and limit >= 0

  defp normalize_exit_behavior(value) when value in [:end, "end"], do: :end
  defp normalize_exit_behavior(value) when value in [:error, "error"], do: :error

  defp normalize_exit_behavior(value) do
    raise ArgumentError, "invalid model call limit exit_behavior: #{inspect(value)}"
  end

  defp limit_exceeded?(%__MODULE__{} = middleware, thread_count, run_count) do
    exceeded?(thread_count, middleware.thread_limit) or exceeded?(run_count, middleware.run_limit)
  end

  defp exceeded?(_count, nil), do: false
  defp exceeded?(count, limit), do: count >= limit

  defp count(state, key) do
    case Map.get(state, key, Map.get(state, Atom.to_string(key), 0)) do
      value when is_integer(value) and value >= 0 -> value
      _other -> 0
    end
  end

  defp limit_message(thread_count, run_count, %__MODULE__{} = middleware) do
    exceeded =
      [
        limit_fragment(:thread, thread_count, middleware.thread_limit),
        limit_fragment(:run, run_count, middleware.run_limit)
      ]
      |> Enum.reject(&is_nil/1)

    "Model call limits exceeded: " <> Enum.join(exceeded, ", ")
  end

  defp limit_fragment(_scope, _count, nil), do: nil
  defp limit_fragment(scope, count, limit), do: "#{scope} limit (#{count}/#{limit})"

  defp limit_details(thread_count, run_count, %__MODULE__{} = middleware) do
    %{
      thread_count: thread_count,
      run_count: run_count,
      thread_limit: middleware.thread_limit,
      run_limit: middleware.run_limit
    }
  end
end
