defmodule BeamWeaver.Graph.Compiled.Batch do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Compiled.Runtime

  def batch(compiled, inputs, opts) when is_list(inputs) do
    Enum.map(inputs, &Runtime.invoke(compiled, &1, opts))
  end

  def batch_as_completed(compiled, inputs, opts) when is_list(inputs) do
    max_concurrency =
      opts
      |> Keyword.get(:max_concurrency, System.schedulers_online())
      |> positive_int()

    timeout = Keyword.get(opts, :timeout, 5_000)

    stream =
      inputs
      |> Enum.with_index()
      |> Task.async_stream(
        fn {input, index} -> {index, Runtime.invoke(compiled, input, opts)} end,
        ordered: false,
        max_concurrency: max_concurrency,
        timeout: timeout,
        on_timeout: :kill_task
      )
      |> Elixir.Stream.map(fn
        {:ok, {index, result}} ->
          {index, result}

        {:exit, reason} ->
          {:unknown, {:error, Error.new(:graph_batch_exit, "graph batch task exited", %{reason: inspect(reason)})}}
      end)

    {:ok, stream}
  rescue
    exception ->
      {:error,
       Error.new(:graph_batch_exception, Exception.message(exception), %{
         exception: inspect(exception.__struct__)
       })}
  end

  defp positive_int(value) when is_integer(value) and value > 0, do: value
  defp positive_int(_value), do: System.schedulers_online()
end
