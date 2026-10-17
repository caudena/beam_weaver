defmodule BeamWeaver.Agent.Decision do
  @moduledoc false

  alias BeamWeaver.Core.Error

  defmodule Jump do
    @moduledoc false

    defstruct destination: nil, update: %{}

    @type t :: %__MODULE__{destination: :model | :tools | :end | nil, update: map()}
  end

  @destinations [:model, :tools, :end]

  @spec normalize(term()) :: {:ok, map()} | {:error, Error.t()}
  def normalize(nil), do: {:ok, %{}}

  def normalize(%Jump{destination: destination, update: update}) when destination in @destinations,
    do: {:ok, Map.put(update, :jump_to, destination)}

  def normalize(%Jump{destination: destination}) do
    {:error,
     Error.new(
       :invalid_agent_middleware_return,
       "jump decision requires a destination of :model, :tools, or :end",
       %{destination: destination}
     )}
  end

  def normalize(%{} = update), do: {:ok, update}
  def normalize({:ok, %{} = update}), do: {:ok, update}

  def normalize({:jump, destination, update}) when destination in @destinations and is_map(update),
    do: {:ok, Map.put(update, :jump_to, destination)}

  def normalize({:halt, update}) when is_map(update), do: {:ok, Map.put(update, :jump_to, :end)}
  def normalize({:error, %Error{} = error}), do: {:error, error}

  def normalize({:error, reason}) do
    {:error, Error.new(:agent_middleware_error, "middleware returned an error", %{reason: inspect(reason)})}
  end

  def normalize(other) do
    {:error,
     Error.new(:invalid_agent_middleware_return, "middleware returned an invalid value", %{returned: inspect(other)})}
  end
end
