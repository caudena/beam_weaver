defmodule BeamWeaver.Template.SimpleTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Template.Simple

  test "a substituted value containing brace text is not re-substituted" do
    # {a} -> "{b}", {b} -> "X". The "{b}" produced by {a} must NOT be replaced again.
    assert {:ok, "{b}X"} = Simple.render("{a}{b}", %{"a" => "{b}", "b" => "X"})
  end

  test "renders ordinary variables" do
    assert {:ok, "hello Ada"} = Simple.render("hello {name}", %{"name" => "Ada"})
  end

  test "errors on a missing variable" do
    assert {:error, %Error{type: :prompt_missing_variable}} = Simple.render("hi {who}", %{})
  end
end
