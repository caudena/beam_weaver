defmodule BeamWeaverTest do
  use ExUnit.Case

  test "root module is documentation-only for the foundation phase" do
    assert Code.ensure_loaded?(BeamWeaver)
  end
end
