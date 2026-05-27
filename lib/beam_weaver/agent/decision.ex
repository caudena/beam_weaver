defmodule BeamWeaver.Agent.Decision do
  @moduledoc """
  Typed internal decisions returned by agent middleware hooks.
  """

  alias BeamWeaver.Core.Error

  defmodule Continue do
    @moduledoc false
    defstruct update: %{}

    @type t :: %__MODULE__{update: map()}
  end

  defmodule Update do
    @moduledoc false
    defstruct update: %{}

    @type t :: %__MODULE__{update: map()}
  end

  defmodule Jump do
    @moduledoc false
    defstruct destination: nil, update: %{}

    @type t :: %__MODULE__{destination: :model | :tools | :end | nil, update: map()}
  end

  defmodule Halt do
    @moduledoc false
    defstruct update: %{}

    @type t :: %__MODULE__{update: map()}
  end

  defmodule Error do
    @moduledoc false
    defstruct [:error]

    @type t :: %__MODULE__{error: BeamWeaver.Core.Error.t()}
  end

  @spec normalize(term()) ::
          {:ok, Continue.t() | Update.t() | Jump.t() | Halt.t()}
          | {:error, BeamWeaver.Core.Error.t()}
  def normalize(nil), do: {:ok, %Continue{}}
  def normalize(%Continue{} = decision), do: {:ok, decision}
  def normalize(%Update{} = decision), do: {:ok, decision}

  def normalize(%Jump{destination: destination} = decision)
      when destination in [:model, :tools, :end], do: {:ok, decision}

  def normalize(%Halt{} = decision), do: {:ok, decision}
  def normalize(%Error{error: %BeamWeaver.Core.Error{} = error}), do: {:error, error}
  def normalize(%{} = update), do: {:ok, %Update{update: update}}
  def normalize({:ok, %{} = update}), do: {:ok, %Update{update: update}}

  def normalize({:jump, destination, update})
      when destination in [:model, :tools, :end] and is_map(update),
      do: {:ok, %Jump{destination: destination, update: update}}

  def normalize({:halt, update}) when is_map(update), do: {:ok, %Halt{update: update}}
  def normalize({:error, %BeamWeaver.Core.Error{} = error}), do: {:error, error}

  def normalize({:error, reason}) do
    {:error,
     BeamWeaver.Core.Error.new(:agent_middleware_error, "middleware returned an error", %{
       reason: inspect(reason)
     })}
  end

  def normalize(other) do
    {:error,
     BeamWeaver.Core.Error.new(
       :invalid_agent_middleware_return,
       "middleware returned an invalid value",
       %{
         returned: inspect(other)
       }
     )}
  end

  @spec to_update(Continue.t() | Update.t() | Jump.t() | Halt.t()) :: map()
  def to_update(%Continue{update: update}), do: update
  def to_update(%Update{update: update}), do: update
  def to_update(%Halt{update: update}), do: Map.put(update, :jump_to, :end)

  def to_update(%Jump{destination: destination, update: update}) do
    Map.put(update, :jump_to, destination)
  end
end
