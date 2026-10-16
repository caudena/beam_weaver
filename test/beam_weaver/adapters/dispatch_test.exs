defmodule BeamWeaver.Adapter.DispatchTest do
  # Not async: the test unloads the real `Checkpoint.ETS` module, which would
  # break any concurrently running test that dispatches to it.
  use ExUnit.Case, async: false

  alias BeamWeaver.Adapter.Dispatch
  alias BeamWeaver.Checkpoint.ETS

  test "loads an adapter module before checking its callback" do
    adapter = ETS.new()
    :code.purge(ETS)
    :code.delete(ETS)

    assert {:ok, ETS} = Dispatch.module(adapter, :get_tuple, 2)
  end

  test "the checkpoint facade loads the saver module before checking its callbacks" do
    saver = ETS.new()
    :code.purge(ETS)
    :code.delete(ETS)

    config = %{"configurable" => %{"thread_id" => "dispatch-test"}}
    entry = %{config: config, checkpoint: %{"id" => "one"}, metadata: %{}, versions: %{}, writes: []}

    assert {:ok, [_config]} = BeamWeaver.Checkpoint.put_many(saver, [entry])
    assert {:ok, %{checkpoint: %{"id" => "one"}}} = BeamWeaver.Checkpoint.fetch_tuple(saver, config)
  end
end
