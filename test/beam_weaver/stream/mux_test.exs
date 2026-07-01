defmodule BeamWeaver.StreamMuxTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Stream
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.Stream.Sink
  alias BeamWeaver.Tracing
  alias BeamWeaver.Tracing.Context

  test "mux emits typed envelopes with producer lifecycle metadata" do
    events =
      Stream.mux(
        [
          model: fn emit ->
            emit.(Stream.event(:token, "hello"))
            :ok
          end
        ],
        run_id: "run-1",
        namespace: [:agent]
      )
      |> Enum.to_list()

    assert [
             %Envelope{event: %Events.Debug{payload: %{type: :producer_start}}, node: :model},
             %Envelope{event: %Events.Token{text: "hello"}, node: :model, run_id: "run-1"},
             %Envelope{event: %Events.Debug{payload: %{type: :producer_stop}}, node: :model}
           ] = events

    assert Enum.all?(events, &(&1.namespace == [:agent]))
  end

  test "mux producers inherit the active trace context" do
    on_exit(fn -> Context.clear() end)

    {:ok, parent} = Tracing.start_run("parent stream", metadata: %{tenant: "alpha"})

    events =
      Stream.mux(
        traced: fn emit ->
          {:ok, child} = Tracing.start_run("producer child", kind: :chain)
          Tracing.finish_run(child)

          emit.(Stream.event(:custom, {child.id, child.trace_id, child.parent_id}))
          :ok
        end
      )
      |> Enum.to_list()

    Tracing.finish_run(parent)

    assert Enum.any?(events, fn
             %Envelope{event: %Events.Custom{payload: {child_id, trace_id, parent_id}}} ->
               child_id != parent.id and trace_id == parent.trace_id and parent_id == parent.id

             _event ->
               false
           end)

    assert {:ok, %{children: [%{run: child}]}} = Tracing.get_tree(parent.id)
    assert child.name == "producer child"
    assert child.metadata == %{tenant: "alpha"}
  end

  test "mux timeout returns a tagged stream timeout error and closes producers" do
    [start, error] =
      Stream.mux(
        [
          slow: fn _emit ->
            Process.sleep(:infinity)
          end
        ],
        timeout: 10
      )
      |> Enum.take(2)

    assert %Envelope{event: %Events.Debug{payload: %{type: :producer_start}}} = start
    assert %Envelope{event: %Events.Error{error: %{type: :stream_timeout}}} = error
  end

  test "mux heartbeats are opt-in and do not finish the producer" do
    [start, heartbeat] =
      Stream.mux(
        [
          slow: fn _emit ->
            Process.sleep(:infinity)
          end
        ],
        heartbeat: 10
      )
      |> Enum.take(2)

    assert %Envelope{event: %Events.Debug{payload: %{type: :producer_start}}} = start
    assert %Envelope{event: %Events.Debug{payload: %{type: :heartbeat}}} = heartbeat
  end

  test "early halt cancels unresolved producer tasks" do
    stream =
      Stream.mux(
        [
          slow: fn emit ->
            emit.(Stream.event(:custom, {:producer_pid, self()}))
            Process.sleep(:infinity)
          end,
          also_slow: fn emit ->
            emit.(Stream.event(:custom, {:producer_pid, self()}))
            Process.sleep(:infinity)
          end
        ],
        heartbeat: 50
      )

    events = Enum.take(stream, 4)

    pids =
      Enum.flat_map(events, fn
        %Envelope{event: %Events.Custom{payload: {:producer_pid, pid}}} -> [pid]
        _event -> []
      end)

    assert length(pids) == 2
    refs = Enum.map(pids, &Process.monitor/1)

    for ref <- refs do
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 500
    end

    refute_receive {:beam_weaver_mux_item, _pid, _item}, 50
  end

  test "sink producers emit child namespace metadata" do
    events =
      Stream.mux(
        [
          {:sink, :graph,
           fn sink ->
             sink
             |> Sink.child(:subgraph)
             |> Sink.emit(Stream.event(:custom, :from_child))

             :ok
           end}
        ],
        namespace: [:parent],
        stream_mode: :events
      )
      |> Enum.to_list()

    assert Enum.any?(
             events,
             &match?(
               %Envelope{
                 event: %Events.Custom{payload: :from_child},
                 namespace: [:parent, :subgraph]
               },
               &1
             )
           )
  end

  test "mux runs producers under a configured task supervisor" do
    parent = self()
    {:ok, supervisor} = Task.Supervisor.start_link()

    stream =
      Stream.mux(
        [
          {:sink, :supervised,
           fn sink ->
             send(parent, {:producer_pid, self()})

             receive do
               :release -> Sink.emit(sink, Stream.event(:custom, :done))
             end

             :ok
           end}
        ],
        producer_supervisor: supervisor
      )

    task = Task.async(fn -> Enum.take(stream, 2) end)

    assert_receive {:producer_pid, producer_pid}, 500
    assert producer_pid in Task.Supervisor.children(supervisor)

    send(producer_pid, :release)

    assert [
             %Envelope{event: %Events.Debug{payload: %{type: :producer_start}}},
             %Envelope{event: %Events.Custom{payload: :done}}
           ] = Task.await(task, 1_000)
  end

  test "drop_newest backpressure policy reports dropped producer events" do
    parent = self()

    stream =
      Stream.mux(
        [
          {:sink, :fast,
           fn sink ->
             for index <- 1..8 do
               result = Sink.emit(sink, Stream.event(:custom, {:overflow, index}))
               send(parent, {:emit_result, result})
             end

             :ok
           end}
        ],
        max_buffer: 0,
        overflow: :drop_newest
      )

    Enum.to_list(stream)
    assert_receive {:emit_result, {:dropped, :newest}}, 200
  end

  test "drop_oldest backpressure policy drops newest when buffer cannot hold any items" do
    parent = self()

    stream =
      Stream.mux(
        [
          {:sink, :fast,
           fn sink ->
             for index <- 1..8 do
               result = Sink.emit(sink, Stream.event(:custom, {:overflow, index}))
               send(parent, {:emit_result, result})
             end

             :ok
           end}
        ],
        max_buffer: 0,
        overflow: :drop_oldest
      )

    Enum.to_list(stream)
    assert_receive {:emit_result, {:dropped, :newest}}, 200
    refute_receive {:emit_result, {:error, %{type: :stream_backpressure}}}, 50
  end

  test "block backpressure policy preserves order after waiting for consumer demand" do
    parent = self()

    events =
      Stream.mux(
        [
          {:sink, :blocking,
           fn sink ->
             send(parent, {:emit_result, Sink.emit(sink, Stream.event(:custom, 1))})
             send(parent, {:emit_result, Sink.emit(sink, Stream.event(:custom, 2))})
             :ok
           end}
        ],
        max_buffer: 1,
        overflow: :block
      )
      |> Enum.to_list()

    assert_receive {:emit_result, :ok}
    assert_receive {:emit_result, :ok}

    assert events
           |> Enum.filter(&match?(%Envelope{event: %Events.Custom{}}, &1))
           |> Enum.map(fn %Envelope{event: %Events.Custom{payload: payload}, node: node} ->
             {node, payload}
           end) == [blocking: 1, blocking: 2]
  end

  test "error backpressure policy reports a typed stream error to the producer" do
    parent = self()

    stream =
      Stream.mux(
        [
          {:sink, :fast,
           fn sink ->
             for index <- 1..8 do
               result = Sink.emit(sink, Stream.event(:custom, {:overflow, index}))
               send(parent, {:emit_result, result})
             end

             :ok
           end}
        ],
        max_buffer: 0,
        overflow: :error
      )

    Enum.to_list(stream)
    assert_receive {:emit_result, {:error, %{type: :stream_backpressure}}}
  end

  test "producer exceptions are converted into typed stream errors" do
    events =
      Stream.mux(
        crashing: fn _emit ->
          raise "boom"
        end
      )
      |> Enum.to_list()

    assert Enum.any?(events, fn
             %Envelope{event: %Events.Error{error: %{type: :stream_error, message: "boom"}}} ->
               true

             _event ->
               false
           end)
  end
end
