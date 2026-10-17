defmodule BeamWeaver.Agent.SpecTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.Spec

  test "interrupt attrs normalize to :all or a list of node names" do
    assert Spec.from_dsl_attrs(__MODULE__, %{interrupt_before: :all}).interrupt_before == :all
    assert Spec.from_dsl_attrs(__MODULE__, %{interrupt_after: "*"}).interrupt_after == :all
    assert Spec.from_dsl_attrs(__MODULE__, %{interrupt_before: :node_a}).interrupt_before == [:node_a]
    assert Spec.from_dsl_attrs(__MODULE__, %{interrupt_after: [:a, :b]}).interrupt_after == [:a, :b]
    assert %Spec{interrupt_before: [], interrupt_after: []} = Spec.from_dsl_attrs(__MODULE__, %{})
  end
end
