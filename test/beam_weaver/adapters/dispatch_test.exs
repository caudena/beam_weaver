defmodule BeamWeaver.Adapter.DispatchTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Adapter.Dispatch
  alias BeamWeaver.Checkpoint.ETS

  test "loads an adapter module before checking its callback" do
    adapter = ETS.new()
    :code.purge(ETS)
    :code.delete(ETS)

    assert {:ok, ETS} = Dispatch.module(adapter, :get_tuple, 2)
  end
end
