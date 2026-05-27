defprotocol BeamWeaver.Graph.Channel.Dispatch do
  @moduledoc """
  Protocol dispatch for graph channels.

  Custom channel structs must implement this protocol, usually by using
  `BeamWeaver.Graph.Channel`.
  """

  def update(channel, updates)
  def get(channel)
  def checkpoint(channel)
  def from_checkpoint(channel, checkpoint)
  def copy(channel)
  def available?(channel)
  def value_type(channel)
  def update_type(channel)
  def null_version(channel)
  def version_equal?(channel, left, right)
  def consume(channel)
  def finish(channel)
end

defmodule BeamWeaver.Graph.Channel do
  @moduledoc """
  Behaviour for LangGraph-style state channels.

  Channels own how updates are accepted, merged, checkpointed, restored, and
  consumed. Public functions return tagged tuples instead of raising.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Channel.Dispatch, as: ChannelDispatch

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

      defoverridable copy: 1,
                     value_type: 1,
                     update_type: 1,
                     null_version: 1,
                     version_equal?: 3,
                     consume: 1,
                     finish: 1

      defimpl BeamWeaver.Graph.Channel.Dispatch, for: __MODULE__ do
        def update(channel, updates), do: @for.update(channel, updates)
        def get(channel), do: @for.get(channel)
        def checkpoint(channel), do: @for.checkpoint(channel)
        def from_checkpoint(channel, checkpoint), do: @for.from_checkpoint(channel, checkpoint)
        def copy(channel), do: @for.copy(channel)
        def available?(channel), do: @for.available?(channel)
        def value_type(channel), do: @for.value_type(channel)
        def update_type(channel), do: @for.update_type(channel)
        def null_version(channel), do: @for.null_version(channel)
        def version_equal?(channel, left, right), do: @for.version_equal?(channel, left, right)
        def consume(channel), do: @for.consume(channel)
        def finish(channel), do: @for.finish(channel)
      end
    end
  end

  def missing, do: @missing

  def update(channel, updates), do: ChannelDispatch.update(channel, updates)
  def get(channel), do: ChannelDispatch.get(channel)
  def checkpoint(channel), do: ChannelDispatch.checkpoint(channel)

  def from_checkpoint(channel, checkpoint),
    do: ChannelDispatch.from_checkpoint(channel, checkpoint)

  def copy(channel), do: ChannelDispatch.copy(channel)
  def available?(channel), do: ChannelDispatch.available?(channel)

  def value_type(channel), do: ChannelDispatch.value_type(channel)

  def update_type(channel), do: ChannelDispatch.update_type(channel)

  def null_version(channel), do: ChannelDispatch.null_version(channel)

  def version_equal?(channel, left, right) do
    ChannelDispatch.version_equal?(channel, left, right)
  end

  def consume(channel), do: ChannelDispatch.consume(channel)

  def finish(channel), do: ChannelDispatch.finish(channel)

  def empty_error(key) do
    Error.new(:empty_channel, "channel has no value", %{channel: key})
  end

  def invalid_update(message, details \\ %{}) do
    Error.new(:invalid_update, message, details)
  end
end
