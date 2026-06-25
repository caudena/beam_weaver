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

  @callback open(keyword()) :: {:ok, term()} | {:error, Error.t()} | term()
  @callback eval(term(), String.t(), keyword()) ::
              {:ok, term(), term()}
              | {:ok, term()}
              | {:error, Error.t(), term()}
              | {:error, Error.t()}
              | term()
  @callback snapshot(term(), keyword()) ::
              {:ok, term()}
              | {:ok, term(), map()}
              | {:error, Error.t()}
              | term()
  @callback restore(term(), keyword()) :: {:ok, term()} | {:error, Error.t()} | term()
  @callback close(term(), keyword()) :: :ok | {:error, Error.t()} | term()

  @optional_callbacks snapshot: 2, restore: 2, close: 2
end
