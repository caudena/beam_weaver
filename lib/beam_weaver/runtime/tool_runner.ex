defmodule BeamWeaver.Runtime.ToolRunner do
  @moduledoc """
  Executes model/tool functions for the runtime task layer.
  """

  alias BeamWeaver.Core.Error, as: CoreError
  alias BeamWeaver.DispatchHook
  alias BeamWeaver.Runtime.Error

  @type emit_fun :: (term() -> :ok)
  @type result :: {:ok, term()} | {:error, Error.t()}

  @doc """
  Runs work and converts failures into tagged runtime errors.
  """
  @spec run(:model | :tool, function(), term(), emit_fun(), keyword()) :: result()
  def run(kind, fun, input, emit, opts \\ [])

  def run(kind, fun, input, emit, opts) when kind in [:model, :tool] and is_function(fun, 0) do
    attempts = if kind == :tool, do: Keyword.get(opts, :max_retries, 0) + 1, else: 1
    run_attempt(kind, fun, input, emit, attempts, opts)
  end

  def run(kind, fun, input, emit, opts) when kind in [:model, :tool] and is_function(fun, 1) do
    attempts = if kind == :tool, do: Keyword.get(opts, :max_retries, 0) + 1, else: 1
    run_attempt(kind, fun, input, emit, attempts, opts)
  end

  def run(kind, fun, input, emit, opts) when kind in [:model, :tool] and is_function(fun, 2) do
    attempts = if kind == :tool, do: Keyword.get(opts, :max_retries, 0) + 1, else: 1
    run_attempt(kind, fun, input, emit, attempts, opts)
  end

  def run(_kind, _fun, _input, _emit, _opts) do
    {:error, Error.new(:invalid_work, "work must be a function with arity 0, 1, or 2")}
  end

  defp run_attempt(kind, fun, input, emit, attempts_left, opts) do
    request = Keyword.get(opts, :dispatch_request, %{kind: kind, input: input})
    hook = Keyword.get(opts, :dispatch_hook)
    context = Keyword.get(opts, :dispatch_context)

    case DispatchHook.before(hook, request, context) do
      :ok ->
        case execute(fun, input, emit) do
          {:error, %Error{}} when attempts_left > 1 ->
            run_attempt(kind, fun, input, emit, attempts_left - 1, opts)

          result ->
            result
        end

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, Error.new(:dispatch_denied, "pre-dispatch hook denied work", %{reason: inspect(reason)})}
    end
  end

  defp execute(fun, input, emit) do
    result =
      case :erlang.fun_info(fun, :arity) do
        {:arity, 0} -> fun.()
        {:arity, 1} -> fun.(input)
        {:arity, 2} -> fun.(input, emit)
      end

    normalize_result(result)
  rescue
    exception ->
      {:error,
       Error.new(:exception, Exception.message(exception), %{
         exception: inspect(exception.__struct__)
       })}
  catch
    kind, reason ->
      {:error,
       Error.new(:execution_failed, "work exited before returning", %{
         kind: kind,
         reason: inspect(reason)
       })}
  end

  defp normalize_result({:ok, _value} = result), do: result
  defp normalize_result({:error, %Error{}} = result), do: result

  defp normalize_result({:error, %CoreError{} = error}) do
    {:error, Error.new(error.type, error.message, error.details)}
  end

  defp normalize_result({:cancelled, %Error{} = error}), do: {:cancelled, error}

  defp normalize_result({:cancelled, reason}) do
    {:cancelled, Error.new(:cancelled, "work acknowledged cancellation", %{reason: inspect(reason)})}
  end

  defp normalize_result({:error, reason}) do
    {:error, Error.new(:execution_failed, "work returned an error", %{reason: inspect(reason)})}
  end

  defp normalize_result(value), do: {:ok, value}
end
