defmodule BeamWeaver.Agent.SpecTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.Spec

  describe "interrupt attr normalization" do
    test "interrupt_before: :all is preserved as :all (not corrupted into [:all])" do
      spec = Spec.from_dsl_attrs(__MODULE__.FakeAgent, %{interrupt_before: :all})
      assert spec.interrupt_before == :all
    end

    test "interrupt_after: :all is preserved as :all" do
      spec = Spec.from_dsl_attrs(__MODULE__.FakeAgent, %{interrupt_after: :all})
      assert spec.interrupt_after == :all
    end

    test ~s(interrupt_before: "*" normalizes to :all) do
      spec = Spec.from_dsl_attrs(__MODULE__.FakeAgent, %{interrupt_before: "*"})
      assert spec.interrupt_before == :all
    end

    test "a single node name is wrapped into a list" do
      spec = Spec.from_dsl_attrs(__MODULE__.FakeAgent, %{interrupt_before: :node_a})
      assert spec.interrupt_before == [:node_a]
    end

    test "a list of node names is preserved" do
      spec = Spec.from_dsl_attrs(__MODULE__.FakeAgent, %{interrupt_after: [:a, :b]})
      assert spec.interrupt_after == [:a, :b]
    end

    test "unset interrupt attrs default to []" do
      spec = Spec.from_dsl_attrs(__MODULE__.FakeAgent, %{})
      assert spec.interrupt_before == []
      assert spec.interrupt_after == []
    end
  end
end
