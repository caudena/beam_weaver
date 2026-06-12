defmodule BeamWeaver.Checkpoint.Saver do
  @moduledoc """
  Behaviour for LangGraph-compatible checkpoint persistence.

  The callbacks mirror the semantic contract of LangGraph's
  `BaseCheckpointSaver`, but keep the API idiomatic for Elixir: the adapter
  struct is always the first argument and recoverable failures return tagged
  tuples.
  """

  @type saver :: struct()
  @type config :: map()
  @type checkpoint :: map()
  @type metadata :: map()
  @type versions :: map()
  @type checkpoint_tuple :: %{
          required(:config) => config(),
          required(:checkpoint) => checkpoint(),
          required(:metadata) => metadata(),
          optional(:parent_config) => config() | nil,
          optional(:pending_writes) => list(),
          optional(:pending_write_paths) => list()
        }

  @callback get_tuple(saver(), config()) :: checkpoint_tuple() | nil
  @callback list(saver(), config() | nil, keyword()) :: [checkpoint_tuple()]
  @callback put(saver(), config(), checkpoint(), metadata(), versions()) ::
              {:ok, config()} | {:error, term()}
  @callback put_writes(saver(), config(), list(), String.t(), String.t()) ::
              :ok | {:error, term()}
  @callback put_checkpoint_with_writes(
              saver(),
              config(),
              checkpoint(),
              metadata(),
              versions(),
              list(),
              keyword()
            ) :: {:ok, config()} | {:error, term()}
  @callback get_delta_channel_history(saver(), config(), [String.t()], keyword()) :: map()
  @callback delete_thread(saver(), String.t()) :: :ok | {:error, term()}
  @callback delete_for_runs(saver(), [String.t()]) :: :ok | {:error, term()}
  @callback copy_thread(saver(), String.t(), String.t()) :: :ok | {:error, term()}
  @callback prune(saver(), [String.t()], keyword()) :: :ok | {:error, term()}
  @callback next_version(saver(), term(), term() | nil) :: term()

  @optional_callbacks put_checkpoint_with_writes: 7

  @doc false
  def next_version(saver, current, channel) do
    if function_exported?(saver.__struct__, :next_version, 3) do
      saver.__struct__.next_version(saver, current, channel)
    else
      default_next_version(current)
    end
  end

  @doc false
  def default_next_version(nil), do: 1
  def default_next_version(version) when is_integer(version), do: version + 1

  def default_next_version(version) when is_binary(version) do
    case Integer.parse(version) do
      {integer, ""} -> Integer.to_string(integer + 1)
      _other -> 1
    end
  end

  def default_next_version(_version), do: 1
end
