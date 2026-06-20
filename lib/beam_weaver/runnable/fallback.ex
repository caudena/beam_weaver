defmodule BeamWeaver.Runnable.Fallback do
  @moduledoc false

  @behaviour BeamWeaver.Runnable

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Result
  alias BeamWeaver.Runnable

  defstruct [:runnable, fallbacks: [], opts: []]

  @impl true
  def invoke(%__MODULE__{} = fallback, input, opts) do
    opts = effective_opts(fallback, opts)

    with :ok <- validate_exception_input(opts, input) do
      fallback
      |> candidates()
      |> run_until_success(input, opts, nil)
    end
  end

  @impl true
  def batch(%__MODULE__{} = fallback, inputs, opts) when is_list(inputs) do
    opts = effective_opts(fallback, opts)

    return_errors? =
      Keyword.get(opts, :return_errors, Keyword.get(opts, :return_exceptions, false))

    results =
      inputs
      |> Task.async_stream(
        fn input ->
          case invoke(fallback, input, opts) do
            {:ok, output} -> {:ok, output}
            {:error, %Error{} = error} when return_errors? -> {:ok, error}
            {:error, %Error{} = error} -> {:error, error}
          end
        end,
        ordered: true,
        max_concurrency: Keyword.get(opts, :max_concurrency, System.schedulers_online()),
        timeout: Keyword.get(opts, :timeout, 300_000),
        on_timeout: :kill_task
      )
      |> Stream.map(fn
        {:ok, result} ->
          result

        {:exit, reason} ->
          {:error,
           Error.new(:runnable_batch_exit, "fallback batch task exited", %{
             reason: inspect(reason)
           })}
      end)
      |> Result.collect()

    case results do
      {:ok, outputs} -> {:ok, outputs}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def batch(%__MODULE__{}, _inputs, _opts),
    do: {:error, Error.new(:invalid_runnable_input, "fallback batch input must be a list")}

  @impl true
  def stream(%__MODULE__{} = fallback, input, opts) do
    opts = effective_opts(fallback, opts)

    with :ok <- validate_exception_input(opts, input) do
      fallback
      |> candidates()
      |> stream_until_success(input, opts, nil)
    end
  end

  def candidates(%__MODULE__{runnable: runnable, fallbacks: fallbacks}),
    do: [runnable | fallbacks]

  defp effective_opts(%__MODULE__{opts: wrapper_opts}, opts),
    do: Keyword.merge(wrapper_opts, opts)

  defp run_until_success([], _input, _opts, nil),
    do: {:error, Error.new(:no_fallbacks, "fallback runnable has no candidates")}

  defp run_until_success([], _input, _opts, %Error{} = error), do: {:error, error}

  defp run_until_success([runnable | rest], input, opts, last_error) do
    next_input = maybe_put_exception(input, fallback_exception_key(opts), last_error)

    case Runnable.invoke(runnable, next_input, opts) do
      {:ok, output} ->
        {:ok, output}

      {:error, %Error{} = error} ->
        if handle_error?(error, opts) do
          run_until_success(rest, input, opts, error)
        else
          {:error, error}
        end
    end
  end

  defp stream_until_success([], _input, _opts, nil),
    do: {:error, Error.new(:no_fallbacks, "fallback runnable has no candidates")}

  defp stream_until_success([], _input, _opts, %Error{} = error), do: {:error, error}

  defp stream_until_success([runnable | rest], input, opts, last_error) do
    next_input = maybe_put_exception(input, fallback_exception_key(opts), last_error)

    case Runnable.stream(runnable, next_input, opts) do
      {:ok, stream} ->
        {:ok, stream}

      {:error, %Error{} = error} ->
        if handle_error?(error, opts) do
          stream_until_success(rest, input, opts, error)
        else
          {:error, error}
        end
    end
  end

  defp fallback_exception_key(opts), do: Keyword.get(opts, :exception_key)

  defp validate_exception_input(opts, input) do
    case Keyword.get(opts, :exception_key) do
      nil ->
        :ok

      _key when is_map(input) ->
        :ok

      key ->
        {:error,
         Error.new(:invalid_runnable_input, "exception_key requires map input", %{
           exception_key: key,
           input: inspect(input)
         })}
    end
  end

  defp maybe_put_exception(input, _key, nil), do: input
  defp maybe_put_exception(input, nil, _error), do: input

  defp maybe_put_exception(input, key, %Error{} = error) when is_map(input),
    do: Map.put(input, key, error)

  defp maybe_put_exception(input, _key, _error), do: input

  defp handle_error?(%Error{} = error, opts) do
    handler = Keyword.get(opts, :exceptions_to_handle, Keyword.get(opts, :retry_on, :all))

    cond do
      handler in [:all, :error] ->
        true

      is_atom(handler) ->
        error.type == handler

      is_list(handler) ->
        error.type in handler

      is_function(handler, 1) ->
        handler.(error) == true

      true ->
        false
    end
  end
end

defimpl BeamWeaver.Runnable.Introspect, for: BeamWeaver.Runnable.Fallback do
  alias BeamWeaver.Runnable
  alias BeamWeaver.Runnable.Graph

  def graph(fallback, _opts), do: Graph.single(fallback)

  def input_schema(%{runnable: runnable}), do: Runnable.input_schema(runnable)

  def output_schema(%{runnable: runnable}), do: Runnable.output_schema(runnable)

  def config_specs(fallback) do
    fallback
    |> BeamWeaver.Runnable.Fallback.candidates()
    |> Enum.flat_map(&Runnable.config_specs/1)
  end
end
