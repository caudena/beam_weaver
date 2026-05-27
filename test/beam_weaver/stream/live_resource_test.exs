defmodule BeamWeaver.Stream.LiveResourceTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.OpenAI.Error, as: OpenAIError
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

    assert [%Events.Custom{payload: :first}] = Enum.take(stream, 1)
    assert_receive :producer_exited, 500
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

    assert_receive {:producer_pid, producer_pid}, 500
    assert producer_pid in Task.Supervisor.children(supervisor)

    send(producer_pid, :release)

    assert [%Events.Custom{payload: :supervised}] = Task.await(task, 1_000)
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
