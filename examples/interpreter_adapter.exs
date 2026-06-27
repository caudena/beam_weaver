defmodule CounterInterpreter do
  @behaviour BeamWeaver.Sandbox.Interpreter

  @impl true
  def open(_opts), do: {:ok, %{counter: 0}}

  @impl true
  def eval(state, "inc", _opts) do
    state = update_in(state.counter, &(&1 + 1))
    {:ok, state.counter, state}
  end

  def eval(state, "get", _opts), do: {:ok, state.counter, state}

  @impl true
  def snapshot(state, _opts), do: {:ok, state, %{runtime: "counter"}}

  @impl true
  def restore(snapshot, _opts), do: {:ok, snapshot}

  @impl true
  def close(_state, _opts), do: :ok
end

alias BeamWeaver.Sandbox.Interpreter.Session

{:ok, session} =
  Session.start(
    adapter: CounterInterpreter,
    timeout: 1_000,
    max_snapshot_bytes: 10_000
  )

{:ok, 1} = Session.eval(session, "inc")
{:ok, snapshot} = Session.snapshot(session)
{:ok, 2} = Session.eval(session, "inc")

{:ok, restored} = Session.start(adapter: CounterInterpreter)
:ok = Session.restore(restored, snapshot)

{:ok, 1} = Session.eval(restored, "get")

Session.close(session)
Session.close(restored)

IO.inspect(snapshot, label: "checkpoint-safe snapshot")
