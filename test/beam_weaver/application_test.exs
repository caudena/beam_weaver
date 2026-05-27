defmodule BeamWeaver.ApplicationTest do
  use ExUnit.Case

  test "process registry registers and looks up runtime processes" do
    key = {:test_process, self(), System.unique_integer([:positive])}

    assert BeamWeaver.ProcessRegistry.lookup(key) == []
    assert {:ok, _pid} = BeamWeaver.ProcessRegistry.register(key, %{kind: :test})

    assert [{pid, %{kind: :test}}] = BeamWeaver.ProcessRegistry.lookup(key)
    assert pid == self()
    assert BeamWeaver.ProcessRegistry.whereis(key) == {:ok, self()}

    assert :ok = BeamWeaver.ProcessRegistry.unregister(key)
    assert BeamWeaver.ProcessRegistry.whereis(key) == :error
  end
end
