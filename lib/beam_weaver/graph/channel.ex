defmodule BeamWeaver.Graph.Channel do
  @moduledoc """
  Behaviour for graph state channels.

  Each key of a graph's state is backed by a channel. Channels own how updates
  are accepted, merged, checkpointed, restored, and consumed. Public functions
  return tagged tuples instead of raising.

  A channel is a struct whose module calls `use BeamWeaver.Graph.Channel`;
  the functions below dispatch to that module.

  At the end of each step, `update/2` gets the step's writes to the key, and a
  channel that holds a value but got no write gets `update(channel, [])`, so a
  channel can drop a value that lasts one step, as
  `BeamWeaver.Graph.Channels.EphemeralValue` does.
  """

  alias BeamWeaver.Core.Error

  @missing :__beam_weaver_missing__

  @type t :: struct()
  @type update_result :: {:ok, t(), boolean()} | {:error, Error.t()}
  @type get_result :: {:ok, term()} | {:error, Error.t()}

  @callback update(t(), [term()]) :: update_result()
  @callback get(t()) :: get_result()
  @callback checkpoint(t()) :: term()
  @callback from_checkpoint(t(), term()) :: t()
  @callback copy(t()) :: t()
  @callback available?(t()) :: boolean()
  @callback value_type(t()) :: term()
  @callback update_type(t()) :: term()
  @callback null_version(t()) :: term()
  @callback version_equal?(t(), term(), term()) :: boolean()
  @callback consume(t()) :: {:ok, t(), boolean()}
  @callback finish(t()) :: {:ok, t(), boolean()}

  @optional_callbacks value_type: 1,
                      update_type: 1,
                      null_version: 1,
                      version_equal?: 3,
                      consume: 1,
                      finish: 1

  defmacro __using__(_opts) do
    quote do
      @behaviour BeamWeaver.Graph.Channel

      alias BeamWeaver.Graph.Channel

      # Defaults for single-value channels, whose struct has `:key` and `:value`.
      @impl true
      def get(%{value: value, key: key}) do
        if value == Channel.missing(), do: {:error, Channel.empty_error(key)}, else: {:ok, value}
      end

      @impl true
      def checkpoint(%{value: value}), do: value

      @impl true
      def from_checkpoint(channel, checkpoint), do: %{channel | value: checkpoint}

      @impl true
      def available?(%{value: value}), do: value != Channel.missing()

      @impl true
      def copy(channel), do: struct(__MODULE__, Map.from_struct(channel))

      @impl true
      def value_type(channel), do: Map.get(Map.from_struct(channel), :type, :any)

      @impl true
      def update_type(channel), do: Map.get(Map.from_struct(channel), :type, :any)

      @impl true
      def null_version(_channel), do: nil

      @impl true
      def version_equal?(_channel, left, right), do: left == right

      @impl true
      def consume(channel), do: {:ok, channel, false}

      @impl true
      def finish(channel), do: {:ok, channel, false}

      defoverridable get: 1,
                     checkpoint: 1,
                     from_checkpoint: 2,
                     available?: 1,
                     copy: 1,
                     value_type: 1,
                     update_type: 1,
                     null_version: 1,
                     version_equal?: 3,
                     consume: 1,
                     finish: 1
    end
  end

  def missing, do: @missing

  @doc "Whether `module` implements this behaviour."
  @spec implemented_by?(module()) :: boolean()
  def implemented_by?(module), do: BeamWeaver.Behaviour.implemented_by?(module, __MODULE__)

  def update(%module{} = channel, updates), do: module.update(channel, updates)
  def get(%module{} = channel), do: module.get(channel)
  def checkpoint(%module{} = channel), do: module.checkpoint(channel)
  def from_checkpoint(%module{} = channel, checkpoint), do: module.from_checkpoint(channel, checkpoint)
  def copy(%module{} = channel), do: module.copy(channel)
  def available?(%module{} = channel), do: module.available?(channel)
  def value_type(%module{} = channel), do: module.value_type(channel)
  def update_type(%module{} = channel), do: module.update_type(channel)
  def null_version(%module{} = channel), do: module.null_version(channel)
  def version_equal?(%module{} = channel, left, right), do: module.version_equal?(channel, left, right)
  def consume(%module{} = channel), do: module.consume(channel)
  def finish(%module{} = channel), do: module.finish(channel)

  def empty_error(key) do
    Error.new(:empty_channel, "channel has no value", %{channel: key})
  end

  def invalid_update(message, details \\ %{}) do
    Error.new(:invalid_update, message, details)
  end
end
