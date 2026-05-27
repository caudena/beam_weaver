defmodule BeamWeaver.Runtime.ToolRunner do
  @moduledoc """
  Executes model/tool functions for the runtime task layer.
  """

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
    run_attempt(fun, input, emit, attempts)
  end

  def run(kind, fun, input, emit, opts) when kind in [:model, :tool] and is_function(fun, 1) do
    attempts = if kind == :tool, do: Keyword.get(opts, :max_retries, 0) + 1, else: 1
    run_attempt(fun, input, emit, attempts)
  end

  def run(kind, fun, input, emit, opts) when kind in [:model, :tool] and is_function(fun, 2) do
    attempts = if kind == :tool, do: Keyword.get(opts, :max_retries, 0) + 1, else: 1
    run_attempt(fun, input, emit, attempts)
  end

  def run(_kind, _fun, _input, _emit, _opts) do
    {:error, Error.new(:invalid_work, "work must be a function with arity 0, 1, or 2")}
  end

  defp run_attempt(fun, input, emit, attempts_left) do
    case execute(fun, input, emit) do
      {:error, %Error{}} when attempts_left > 1 ->
        run_attempt(fun, input, emit, attempts_left - 1)

      result ->
        result
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

  defp normalize_result({:error, reason}) do
    {:error, Error.new(:execution_failed, "work returned an error", %{reason: inspect(reason)})}
  end

  defp normalize_result(value), do: {:ok, value}
end
