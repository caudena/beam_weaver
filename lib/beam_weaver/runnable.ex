defmodule BeamWeaver.Runnable do
  @moduledoc """
  Uniform `invoke/3`, `batch/3`, `stream/3`, and `transform/3` over prompts,
  chat models, output parsers, compiled graphs, and plain functions.

  Structs participate by implementing this behaviour; one- and two-arity
  functions are wrapped automatically. Compose with `sequence/2` or plain
  Elixir functions.

  A chat model runs through `BeamWeaver.Core.ChatModel.invoke/3` (or
  `BeamWeaver.Core.ChatModel.stream/3`), so it takes a string, a formatted
  prompt or a list of messages, and a sequence can pipe a prompt into a model.
  It gets the call's options, such as `temperature:`, but not the run's own
  `tags:`, `metadata:` or `run_id:`.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Runnable.Runtime

  @callback invoke(term(), term(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  @callback batch(term(), [term()], keyword()) :: {:ok, [term()]} | {:error, Error.t()}
  @callback stream(term(), term(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  @callback transform(term(), Enumerable.t(), keyword()) ::
              {:ok, Enumerable.t()} | {:error, Error.t()}
  @optional_callbacks batch: 3, stream: 3, transform: 3

  @type runnable :: term()

  def lambda(fun, opts \\ []), do: %BeamWeaver.Runnable.Lambda{fun: fun, name: opts[:name]}

  def sequence(runnables, opts \\ []),
    do: %BeamWeaver.Runnable.Sequence{steps: List.wrap(runnables), name: opts[:name]}

  @doc "Returns the display name for a runnable."
  defdelegate name(runnable), to: Runtime

  @doc "Invokes a runnable with one input."
  @spec invoke(runnable(), term(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  defdelegate invoke(runnable, input, opts \\ []), to: Runtime

  @doc "Invokes a runnable for each input and returns ordered results."
  @spec batch(runnable(), [term()], keyword()) :: {:ok, [term()]} | {:error, Error.t()}
  defdelegate batch(runnable, inputs, opts \\ []), to: Runtime

  @doc "Streams a runnable result for one input."
  @spec stream(runnable(), term(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  defdelegate stream(runnable, input, opts \\ []), to: Runtime

  @doc "Transforms an input enumerable through a runnable."
  @spec transform(runnable(), Enumerable.t(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  defdelegate transform(runnable, input, opts \\ []), to: Runtime
end
