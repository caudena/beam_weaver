defmodule BeamWeaver.Runnable.Map do
  @moduledoc false

  @behaviour BeamWeaver.Runnable

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Runnable
  alias BeamWeaver.Runnable.Config

  defstruct [:runnable]

  @impl true
  def invoke(%__MODULE__{runnable: runnable}, inputs, opts) when is_list(inputs) do
    Runnable.batch(runnable, inputs, opts)
  end

  def invoke(%__MODULE__{}, _inputs, _opts),
    do: {:error, Error.new(:invalid_runnable_input, "map requires a list input")}

  @impl true
  def stream(%__MODULE__{runnable: runnable}, inputs, opts) when is_list(inputs) do
    config = Config.normalize(opts)

    stream =
      inputs
      |> Task.async_stream(
        fn input -> Runnable.invoke(runnable, input, opts) end,
        ordered: true,
        max_concurrency: config.max_concurrency,
        timeout: Keyword.get(opts, :timeout, 5_000),
        on_timeout: :kill_task
      )
      |> Stream.map(fn
        {:ok, {:ok, output}} ->
          output

        {:ok, {:error, %Error{} = error}} ->
          error

        {:exit, reason} ->
          Error.new(:runnable_map_exit, "map runnable exited", %{reason: inspect(reason)})
      end)

    {:ok, stream}
  end

  def stream(%__MODULE__{}, _inputs, _opts),
    do: {:error, Error.new(:invalid_runnable_input, "map requires a list input")}
end
