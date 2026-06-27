defmodule BeamWeaver.Sandbox.Interpreter.SessionTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Sandbox.Interpreter.Session
  alias BeamWeaver.Sandbox.Interpreter.Snapshot

  defmodule FakeInterpreter do
    @behaviour BeamWeaver.Sandbox.Interpreter

    alias BeamWeaver.Core.Error

    @impl true
    def open(opts) do
      {:ok, %{vars: %{}, owner: Keyword.get(opts, :owner), closed?: false}}
    end

    @impl true
    def eval(state, "sleep", _opts) do
      Process.sleep(:infinity)
      {:ok, :unreachable, state}
    end

    def eval(state, "adapter_error", _opts) do
      {:error, Error.new(:fake_interpreter_error, "fake adapter error"), state}
    end

    def eval(_state, "raise", _opts) do
      raise "fake crash"
    end

    def eval(state, "state_size", _opts) do
      {:ok, map_size(state.vars), state}
    end

    def eval(state, "get " <> key, _opts) do
      {:ok, Map.get(state.vars, key), state}
    end

    def eval(state, "set " <> rest, _opts) do
      [key, value] = String.split(rest, " ", parts: 2)
      state = put_in(state.vars[key], value)
      {:ok, value, state}
    end

    def eval(state, code, _opts), do: {:ok, code, state}

    @impl true
    def snapshot(state, _opts) do
      {:ok, state.vars, %{api_key: "sk-secret", source: "fake"}}
    end

    @impl true
    def restore(vars, opts) when is_map(vars) do
      {:ok, %{vars: vars, owner: Keyword.get(opts, :owner), closed?: false}}
    end

    @impl true
    def close(state, _opts) do
      if is_pid(state.owner), do: send(state.owner, {:fake_interpreter_closed, self()})
      :ok
    end
  end

  defmodule MinimalInterpreter do
    @behaviour BeamWeaver.Sandbox.Interpreter

    @impl true
    def open(_opts), do: %{}

    @impl true
    def eval(state, code, _opts), do: {:ok, code, state}
  end

  test "fake interpreter eval preserves state and snapshots restore tagged data" do
    {:ok, pid} = Session.start(adapter: FakeInterpreter, owner: self())

    assert {:ok, "42"} = Session.eval(pid, "set answer 42")
    assert {:ok, "42"} = Session.eval(pid, "get answer")

    assert {:ok, %Snapshot{} = snapshot} = Session.snapshot(pid)
    assert snapshot.adapter == FakeInterpreter
    assert snapshot.data == %{"answer" => "42"}
    assert snapshot.size_bytes > 0
    assert snapshot.metadata.api_key == "**REDACTED**"
    assert snapshot.metadata.source == "fake"

    {:ok, restored} = Session.start(adapter: FakeInterpreter, owner: self())
    assert :ok = Session.restore(restored, snapshot)
    assert {:ok, "42"} = Session.eval(restored, "get answer")

    assert :ok = Session.close(pid)
    assert :ok = Session.close(restored)
    assert_receive {:fake_interpreter_closed, _pid}
  end

  test "oversized snapshots and adapter mismatches return normalized errors" do
    {:ok, pid} = Session.start(adapter: FakeInterpreter, max_snapshot_bytes: 20)
    large = String.duplicate("x", 100)

    assert {:ok, ^large} = Session.eval(pid, "set large #{large}")

    assert {:error, %Error{type: :interpreter_snapshot_too_large, details: details}} =
             Session.snapshot(pid)

    assert details.size_bytes > details.max_snapshot_bytes

    {:ok, other} = Session.start(adapter: MinimalInterpreter)

    assert {:error, %Error{type: :interpreter_snapshot_adapter_mismatch}} =
             Session.restore(other, %Snapshot{adapter: FakeInterpreter, data: %{}, size_bytes: 1})

    Session.close(pid)
    Session.close(other)
  end

  test "bounded eval timeout cancels adapter task and keeps session alive" do
    parent = self()
    ref = make_ref()
    attach_id = "beam-weaver-interpreter-telemetry-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      attach_id,
      [
        [:beam_weaver, :sandbox, :interpreter, :eval, :start],
        [:beam_weaver, :sandbox, :interpreter, :eval, :timeout]
      ],
      &__MODULE__.handle_telemetry/4,
      {parent, ref}
    )

    on_exit(fn -> :telemetry.detach(attach_id) end)

    {:ok, pid} = Session.start(adapter: FakeInterpreter, timeout: 25)

    assert {:error, %Error{type: :interpreter_timeout, details: %{operation: :eval}}} =
             Session.eval(pid, "sleep", timeout: 25)

    assert Process.alive?(pid)
    assert {:ok, 0} = Session.eval(pid, "state_size")

    assert_receive {^ref, [:beam_weaver, :sandbox, :interpreter, :eval, :start], %{system_time: _},
                    %{adapter: FakeInterpreter, operation: :eval}}

    assert_receive {^ref, [:beam_weaver, :sandbox, :interpreter, :eval, :timeout], %{duration: _},
                    %{adapter: FakeInterpreter, operation: :eval}}

    Session.close(pid)
  end

  test "adapter errors and crashes are normalized without killing the session" do
    {:ok, pid} = Session.start(adapter: FakeInterpreter)

    assert {:error, %Error{type: :fake_interpreter_error}} = Session.eval(pid, "adapter_error")
    assert {:error, %Error{type: :interpreter_execution_failed}} = Session.eval(pid, "raise")
    assert Process.alive?(pid)

    Session.close(pid)
  end

  test "adapters without snapshot callbacks stay explicit" do
    {:ok, pid} = Session.start(adapter: MinimalInterpreter)

    assert {:ok, "hello"} = Session.eval(pid, "hello")
    assert {:error, %Error{type: :interpreter_snapshot_unsupported}} = Session.snapshot(pid)

    Session.close(pid)
  end

  def handle_telemetry(event, measurements, metadata, {pid, ref}) do
    send(pid, {ref, event, measurements, metadata})
  end
end
