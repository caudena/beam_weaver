defmodule BeamWeaver.Compaction.RehydrationState do
  @moduledoc """
  Hashed deterministic state retained independently from semantic text.

  Applications use this value for exact continuation data that must not be
  paraphrased by a summary model, such as Todo or workspace revisions. Data
  must be canonical JSON and is limited to 1 MiB.
  """

  alias BeamWeaver.Compaction.Canonical
  alias BeamWeaver.Core.Error

  @maximum_bytes 1_048_576

  @enforce_keys [:data, :hash]
  defstruct @enforce_keys

  @type t :: %__MODULE__{data: map(), hash: String.t()}

  @doc "Builds rehydration state and computes its canonical hash."
  @spec new(map() | t()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = state), do: validate(state)

  def new(%{} = data) do
    state = %__MODULE__{data: data, hash: Canonical.hash(data)}
    validate(state)
  end

  def new(_data), do: {:error, Error.new(:invalid_rehydration_state, "rehydration state must be a map")}

  @doc "Validates canonical data, its stored hash, and the byte limit."
  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = state) do
    with true <- Canonical.json_value?(state.data),
         true <- Canonical.hash(state.data) == state.hash,
         {:ok, size} <- Canonical.encoded_size(state.data),
         true <- size <= @maximum_bytes do
      {:ok, state}
    else
      _error -> {:error, Error.new(:invalid_rehydration_state, "rehydration state is invalid")}
    end
  end
end
