defmodule BeamWeaver.Agent.FinalResponsePolicy do
  @moduledoc """
  Extracts final agent outputs from state.

  Agent public APIs still return the full graph state by default. This policy is
  the internal and testable extraction primitive used by callers that want a
  LangChain-style final response projection.
  """

  alias BeamWeaver.Agent.State
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message

  defstruct mode: :state

  @type mode :: :latest_assistant | :structured | :messages | :state
  @type t :: %__MODULE__{mode: mode()}

  @spec new(keyword() | mode()) :: t()
  def new(mode) when mode in [:latest_assistant, :structured, :messages, :state],
    do: %__MODULE__{mode: mode}

  def new(opts) when is_list(opts), do: %__MODULE__{mode: Keyword.get(opts, :mode, :state)}

  @spec extract(t() | mode(), map()) :: {:ok, term()} | {:error, Error.t()}
  def extract(mode, state) when is_atom(mode), do: extract(new(mode), state)

  def extract(%__MODULE__{mode: :state}, state), do: {:ok, state}

  def extract(%__MODULE__{mode: :messages}, state) do
    {:ok, State.messages(state)}
  end

  def extract(%__MODULE__{mode: :structured}, state) do
    if State.structured_response?(state) do
      {:ok, State.structured_response(state)}
    else
      latest_assistant(state)
    end
  end

  def extract(%__MODULE__{mode: :latest_assistant}, state), do: latest_assistant(state)

  def extract(%__MODULE__{mode: mode}, _state) do
    {:error, Error.new(:invalid_final_response_policy, "unsupported final response mode", %{mode: mode})}
  end

  defp latest_assistant(state) do
    state
    |> State.messages()
    |> Enum.reverse()
    |> Enum.find(&match?(%Message{role: :assistant}, &1))
    |> case do
      %Message{tool_calls: calls} = message when calls in [nil, []] -> {:ok, message}
      %Message{} = message -> {:ok, message}
      nil -> {:error, Error.new(:missing_final_response, "agent state has no assistant message")}
    end
  end
end
