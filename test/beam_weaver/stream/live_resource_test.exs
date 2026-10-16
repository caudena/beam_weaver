defmodule BeamWeaver.Stream.LiveResourceTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Error, as: OpenAIError
  alias BeamWeaver.Stream
  alias BeamWeaver.Stream.Events

  test "live_resource emits heartbeat and cancels producer on early halt" do
    parent = self()

    stream =
      Stream.live_resource(
        fn emit ->
          try do
            emit.(%Events.Custom{payload: :first})
            Process.sleep(:infinity)
          after
            send(parent, :producer_exited)
          end
        end,
        timeout: 5,
        on_cancel: fn -> send(parent, :producer_exited) end
      )

    # `timeout:` is the heartbeat interval, so heartbeats may come before the
    # item; once the producer goes quiet after it, the next event is a heartbeat.
    assert [%Events.Custom{payload: :first}, %Events.Debug{payload: %{type: :heartbeat}}] =
             stream
             |> Elixir.Stream.drop_while(&(not match?(%Events.Custom{}, &1)))
             |> Enum.take(2)

    assert_receive :producer_exited
  end

  test "live_resource can run producers under a task supervisor" do
    parent = self()
    {:ok, supervisor} = Task.Supervisor.start_link()

    stream =
      Stream.live_resource(
        fn emit ->
          send(parent, {:producer_pid, self()})

          receive do
            :release -> emit.(%Events.Custom{payload: :supervised})
          end

          :ok
        end,
        producer_supervisor: supervisor
      )

    task = Task.async(fn -> Enum.take(stream, 1) end)

    assert_receive {:producer_pid, producer_pid}
    assert producer_pid in Task.Supervisor.children(supervisor)

    send(producer_pid, :release)

    assert [%Events.Custom{payload: :supervised}] = Task.await(task, 5_000)
  end

  test "live_resource stops its producer when the consumer exits" do
    parent = self()

    consumer =
      spawn(fn ->
        Stream.live_resource(fn _emit ->
          send(parent, {:producer_pid, self()})

          receive do
            {:ping, from} -> send(from, :pong)
          end

          Process.sleep(:infinity)
        end)
        |> Enum.to_list()
      end)

    assert_receive {:producer_pid, producer}
    producer_ref = Process.monitor(producer)

    # Monitoring is asynchronous, and the kill below reaches the producer from
    # another process, so it could overtake the monitor request and turn the
    # :DOWN into `:noproc`. Signals between two processes stay in order, so once
    # the producer answers this ping the monitor is in place.
    send(producer, {:ping, self()})
    assert_receive :pong

    Process.exit(consumer, :kill)
    assert_receive {:DOWN, ^producer_ref, :process, ^producer, :killed}
  end

  test "live_resource reports supervised producer crashes as stream errors" do
    {:ok, supervisor} = Task.Supervisor.start_link()

    assert [%Events.Error{error: %{type: :stream_error, message: "boom"}}] =
             Stream.live_resource(
               fn _emit -> raise "boom" end,
               producer_supervisor: supervisor
             )
             |> Enum.to_list()
  end

  test "live_resource preserves tagged provider errors" do
    error = OpenAIError.new(:context_overflow, "too long")

    assert [%Events.Error{error: ^error}] =
             Stream.live_resource(fn _emit -> {:error, error} end)
             |> Enum.to_list()
  end
end
