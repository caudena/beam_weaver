defmodule BeamWeaver.Template.SimpleTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Template.Simple

  test "a substituted value containing brace text is not re-substituted" do
    # {a} -> "{b}", {b} -> "X". The "{b}" produced by {a} must NOT be replaced again.
    assert {:ok, "{b}X"} = Simple.render("{a}{b}", %{"a" => "{b}", "b" => "X"}, [])
  end
end
