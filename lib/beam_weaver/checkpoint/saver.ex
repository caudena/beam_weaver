defmodule BeamWeaver.Checkpoint.Saver do
  @moduledoc """
  The behaviour of checkpoint savers, which store a thread's state after every
  step.

  BeamWeaver ships `BeamWeaver.Checkpoint.ETS` for development and tests and
  `BeamWeaver.Checkpoint.Ecto` for Postgres and SQLite. Implement this
  behaviour to store checkpoints somewhere else. The saver struct is the first
  argument of every callback, and failures return `{:error, reason}`.

  | Callback | Purpose |
  | --- | --- |
  | `c:get_tuple/2` | The latest checkpoint of a thread, or the one `config` names. |
  | `c:list/3` | A thread's checkpoints, newest first, for history. |
  | `c:put/5` | Store a checkpoint and return its config. |
  | `c:put_writes/5` | Store the pending writes of a task in a step. |
  | `c:get_delta_channel_history/4` | The write history of delta channels. |
  | `c:delete_thread/2`, `c:delete_for_runs/2`, `c:copy_thread/3`, `c:prune/3` | Maintenance. |
  | `c:next_version/3` | The next version of a channel. |
  | `c:fetch_tuple/2`, `c:list_result/3` | Optional forms of `get_tuple/2` and `list/3` that return storage errors. |
  | `c:put_checkpoint_with_writes/7` | Optional: store a checkpoint and its writes atomically. |
  | `c:put_many/3` | Optional: store a batch of checkpoints all or nothing. |
  | `c:fork_at/4` | Optional: copy a checkpoint's history into a new thread. |

  Use the functions in `BeamWeaver.Checkpoint` rather than calling a saver
  directly: they add telemetry and normalize what savers return. See
  [Checkpoints](checkpoints.md#write-a-custom-saver).
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
  @callback fetch_tuple(saver(), config()) ::
              {:ok, checkpoint_tuple() | nil} | {:error, term()}
  @callback list_result(saver(), config() | nil, keyword()) ::
              {:ok, [checkpoint_tuple()]} | {:error, term()}
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
  @callback put_many(saver(), [map()], keyword()) ::
              {:ok, [config()]} | {:error, term()}
  @callback fork_at(saver(), config(), String.t(), keyword()) ::
              {:ok, config()} | {:error, term()}
  @callback get_delta_channel_history(saver(), config(), [String.t()], keyword()) :: map()
  @callback delete_thread(saver(), String.t()) :: :ok | {:error, term()}
  @callback delete_for_runs(saver(), [String.t()]) :: :ok | {:error, term()}
  @callback copy_thread(saver(), String.t(), String.t()) :: :ok | {:error, term()}
  @callback prune(saver(), [String.t()], keyword()) :: :ok | {:error, term()}
  @callback next_version(saver(), term(), term() | nil) :: term()

  @optional_callbacks fetch_tuple: 2,
                      list_result: 3,
                      put_checkpoint_with_writes: 7,
                      put_many: 3,
                      fork_at: 4

  @doc false
  def next_version(saver, current, channel) do
    if BeamWeaver.Behaviour.exported?(saver.__struct__, :next_version, 3) do
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
