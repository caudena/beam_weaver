defmodule BeamWeaver.Runnable.Passthrough do
  @moduledoc false

  @behaviour BeamWeaver.Runnable

  defstruct []

  @impl true
  def invoke(%__MODULE__{}, input, _opts), do: {:ok, input}

  @impl true
  def stream(%__MODULE__{}, input, _opts), do: {:ok, [input]}

  @impl true
  def transform(%__MODULE__{}, input, _opts), do: {:ok, input}
end

defimpl BeamWeaver.Runnable.Spec, for: BeamWeaver.Runnable.Passthrough do
  def to_spec(_runnable), do: {:ok, %{"type" => "passthrough"}}
end
