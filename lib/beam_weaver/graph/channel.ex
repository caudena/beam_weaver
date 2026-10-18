defmodule BeamWeaver.Graph.Channel do
  @moduledoc ~S"""
  State-key behavior for merging, persistence and consumption.

  A channel receives all writes for its key at a superstep boundary, including
  an empty list when no node wrote it. This lets ephemeral channels expire data.
  `update/2` returns the new channel plus whether it changed; `get/1` returns
  its value or an empty-channel error. Other callbacks have their own return
  contracts below.

  `use BeamWeaver.Graph.Channel` supplies single-value defaults that adapters
  can override. Keep checkpoint/restore deterministic and replay preparation
  idempotent. Use the built-in channels unless your data needs another merge or
  storage policy. See [State and Channels](graph_state.md).
  """

  alias BeamWeaver.Core.Error

  @missing :__beam_weaver_missing__

  @type t :: struct()
  @type update_result :: {:ok, t(), boolean()} | {:error, Error.t()}
  @type get_result :: {:ok, term()} | {:error, Error.t()}

  @doc """
  Applies this step's writes and returns {:ok, channel, changed?} or an invalid-update error.
  """
  @callback update(t(), [term()]) :: update_result()
  @doc """
  Returns {:ok, value} or an empty-channel error.
  """
  @callback get(t()) :: get_result()
  @doc """
  Returns the serializable checkpoint representation or the missing sentinel.
  """
  @callback checkpoint(t()) :: term()
  @doc """
  Restores a channel value from its saved representation.
  """
  @callback from_checkpoint(t(), term()) :: t()
  @doc """
  Returns an independent channel value with the same current state.
  """
  @callback copy(t()) :: t()
  @doc """
  Reports whether a value is currently available for node input.
  """
  @callback available?(t()) :: boolean()
  @doc """
  Describes the stored value type for introspection.
  """
  @callback value_type(t()) :: term()
  @doc """
  Describes the accepted update type for introspection.
  """
  @callback update_type(t()) :: term()
  @doc """
  Returns the channel's empty version marker.
  """
  @callback null_version(t()) :: term()
  @doc """
  Compares two versions using the channel's version semantics.
  """
  @callback version_equal?(t(), term(), term()) :: boolean()
  @doc """
  Notifies the channel that its value was consumed; returns channel and change flag.
  """
  @callback consume(t()) :: {:ok, t(), boolean()}
  @doc """
  Notifies the channel of execution completion; returns channel and change flag.
  """
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
      @doc """
      Returns {:ok, value} or an empty-channel error.
      """
      def get(%{value: value, key: key}) do
        if value == Channel.missing(), do: {:error, Channel.empty_error(key)}, else: {:ok, value}
      end

      @impl true
      @doc """
      Returns the serializable checkpoint representation or the missing sentinel.
      """
      def checkpoint(%{value: value}), do: value

      @impl true
      @doc """
      Restores a channel value from its saved representation.
      """
      def from_checkpoint(channel, checkpoint), do: %{channel | value: checkpoint}

      @impl true
      @doc """
      Reports whether a value is currently available for node input.
      """
      def available?(%{value: value}), do: value != Channel.missing()

      @impl true
      @doc """
      Returns an independent channel value with the same current state.
      """
      def copy(channel), do: struct(__MODULE__, Map.from_struct(channel))

      @impl true
      @doc """
      Describes the stored value type for introspection.
      """
      def value_type(channel), do: Map.get(Map.from_struct(channel), :type, :any)

      @impl true
      @doc """
      Describes the accepted update type for introspection.
      """
      def update_type(channel), do: Map.get(Map.from_struct(channel), :type, :any)

      @impl true
      @doc """
      Returns the channel's empty version marker.
      """
      def null_version(_channel), do: nil

      @impl true
      @doc """
      Compares two versions using the channel's version semantics.
      """
      def version_equal?(_channel, left, right), do: left == right

      @impl true
      @doc """
      Notifies the channel that its value was consumed; returns channel and change flag.
      """
      def consume(channel), do: {:ok, channel, false}

      @impl true
      @doc """
      Notifies the channel of execution completion; returns channel and change flag.
      """
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

  @doc """
  Applies this step's writes and returns {:ok, channel, changed?} or an invalid-update error.
  """
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
