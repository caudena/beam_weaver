defmodule BeamWeaver.Agent.DecisionTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.Decision
  alias BeamWeaver.Agent.Decision.Jump
  alias BeamWeaver.Core.Error

  test "a Jump with a nil destination is an error, not silently wrapped in an Update" do
    assert {:error, %Error{type: :invalid_agent_middleware_return}} =
             Decision.normalize(%Jump{destination: nil})
  end

  test "a Jump with an unknown destination is an error" do
    assert {:error, %Error{type: :invalid_agent_middleware_return}} =
             Decision.normalize(%Jump{destination: :nowhere})
  end

  test "a Jump with a valid destination is accepted" do
    assert {:ok, %{jump_to: :model}} = Decision.normalize(%Jump{destination: :model})
    assert {:ok, %{jump_to: :tools}} = Decision.normalize(%Jump{destination: :tools})
    assert {:ok, %{jump_to: :end}} = Decision.normalize(%Jump{destination: :end})
  end
end
