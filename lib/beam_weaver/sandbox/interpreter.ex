defmodule BeamWeaver.Sandbox.Interpreter do
  @moduledoc """
  Adapter contract for sandboxed interpreter sessions.

  BeamWeaver owns the OTP session boundary, timeout/cancel handling, snapshots,
  and telemetry. Adapter modules own the language runtime and must be provided
  explicitly by the application.
  """

  alias BeamWeaver.Core.Error

  defmodule Snapshot do
    @moduledoc """
    Tagged interpreter state that can be persisted by BeamWeaver checkpoints.
    """

    @enforce_keys [:adapter, :data, :size_bytes]
    defstruct [:adapter, :data, :size_bytes, version: 1, metadata: %{}]

    @type t :: %__MODULE__{
            adapter: module(),
            data: term(),
            size_bytes: non_neg_integer(),
            version: pos_integer(),
            metadata: map()
          }
  end

  @doc """
  Initializes adapter state for a new session.
  """
  @callback open(keyword()) :: {:ok, term()} | {:error, Error.t()} | term()
  @doc """
  Evaluates source text. The three-element success form returns value and next state; an explicit error can also supply next state.
  """
  @callback eval(term(), String.t(), keyword()) ::
              {:ok, term(), term()}
              | {:ok, term()}
              | {:error, Error.t(), term()}
              | {:error, Error.t()}
              | term()
  @doc """
  Optional serialization of adapter state to plain bounded data, with optional metadata.
  """
  @callback snapshot(term(), keyword()) ::
              {:ok, term()}
              | {:ok, term(), map()}
              | {:error, Error.t()}
              | term()
  @doc """
  Optional restoration from saved snapshot data to adapter state.
  """
  @callback restore(term(), keyword()) :: {:ok, term()} | {:error, Error.t()} | term()
  @doc """
  Optional cleanup of resources owned by the adapter state.
  """
  @callback close(term(), keyword()) :: :ok | {:error, Error.t()} | term()

  @optional_callbacks snapshot: 2, restore: 2, close: 2
end
