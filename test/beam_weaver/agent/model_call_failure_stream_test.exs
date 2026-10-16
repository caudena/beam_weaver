defmodule BeamWeaver.Agent.ModelCallFailureStreamTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.Middleware.ModelFallback
  alias BeamWeaver.Agent.Middleware.ModelRetry
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.Transport.Response

  # Answers each request with the next scripted reply: an Anthropic event
  # stream (a binary) or an HTTP error (`{status, body}`).
  defmodule Scripted do
    @behaviour BeamWeaver.Transport

    @impl true
    def request(_request, opts) do
      case Agent.get_and_update(Keyword.fetch!(opts, :script), fn [next | rest] -> {next, rest} end) do
        {status, body} ->
          {:ok, Response.new(status: status, headers: [{"content-type", "application/json"}], body: body)}

        stream ->
          {:ok, Response.new(status: 200, headers: [{"content-type", "text/event-stream"}], body: stream)}
      end
    end
  end

  # An agent whose model reads its script when the agent runs.
  defmodule RetriedAgent do
    use BeamWeaver.Agent

    model "anthropic:claude-haiku-4-5",
      api_key: "k",
      stream: true,
      transport: BeamWeaver.Agent.ModelCallFailureStreamTest.Scripted,
      transport_opts: [
        script: :persistent_term.get({BeamWeaver.Agent.ModelCallFailureStreamTest.RetriedAgent, :script})
      ]

    middleware [{BeamWeaver.Agent.Middleware.ModelRetry, max_retries: 1}]
  end

  describe "a streamed model call that fails partway" do
    test "and ModelRetry retries: the run's stream has no Error event, only the failed call's Debug event" do
      agent =
        agent([cut_off("overloaded_error", "Overloaded"), reply("It shipped on Monday.")], [
          {ModelRetry, max_retries: 1}
        ])

      assert {:ok, events} = BeamWeaver.Agent.stream_events(agent, %{messages: ["Where is A-1001?"]}, live: true)
      events = Enum.to_list(events)

      refute Enum.any?(events, &match?(%Envelope{event: %Events.Error{}}, &1))

      assert [
               {:token, "It shipped on"},
               {:model_call_failed, %Error{type: :http_error, message: "Overloaded", details: %{status: 529}}, "model"},
               {:token, "It shipped on Monday."},
               {:answer, "It shipped on Monday."}
             ] = timeline(events)
    end

    test "and ModelRetry retries: a collected stream has no Error event either" do
      agent =
        agent([cut_off("overloaded_error", "Overloaded"), reply("It shipped on Monday.")], [
          {ModelRetry, max_retries: 1}
        ])

      assert {:ok, events} = BeamWeaver.Agent.stream_events(agent, %{messages: ["Where is A-1001?"]})
      refute Enum.any?(events, &match?(%Envelope{event: %Events.Error{}}, &1))
      assert {:answer, "It shipped on Monday."} = List.last(timeline(events))
    end

    test "and ModelFallback answers: the run's stream has no Error event" do
      script = start_script([cut_off("overloaded_error", "Overloaded"), reply("It shipped on Monday.")])
      fallback = BeamWeaver.Models.init_chat_model!("anthropic:claude-haiku-4-5", model_opts(script))
      agent = agent(script, [{ModelFallback, fallbacks: [fallback]}])

      assert {:ok, events} = BeamWeaver.Agent.stream_events(agent, %{messages: ["Where is A-1001?"]}, live: true)
      events = Enum.to_list(events)

      refute Enum.any?(events, &match?(%Envelope{event: %Events.Error{}}, &1))
      assert [{:token, _}, {:model_call_failed, %Error{}, "model"}, {:token, _}, {:answer, _}] = timeline(events)
    end

    test "and nothing recovers: the run's stream ends with its one Error event" do
      agent = agent([cut_off("overloaded_error", "Overloaded")], [])

      assert {:ok, events} = BeamWeaver.Agent.stream_events(agent, %{messages: ["Where is A-1001?"]}, live: true)
      events = Enum.to_list(events)

      assert [%Envelope{event: %Events.Error{error: %Error{type: :http_error, message: "Overloaded"}}, node: nil}] =
               Enum.filter(events, &match?(%Envelope{event: %Events.Error{}}, &1))

      assert %Envelope{event: %Events.Error{}} = List.last(events)

      assert [{:token, "It shipped on"}, {:model_call_failed, %Error{type: :http_error}, "model"}] = timeline(events)
    end
  end

  test "a subgraph whose model call was retried counts as completed" do
    script = start_script([cut_off("overloaded_error", "Overloaded"), reply("It shipped on Monday.")])
    :persistent_term.put({RetriedAgent, :script}, script)
    on_exit(fn -> :persistent_term.erase({RetriedAgent, :script}) end)

    desk =
      BeamWeaver.Graph.new()
      |> BeamWeaver.Graph.add_node(:support, RetriedAgent,
        input: fn %{ticket: ticket} -> %{messages: [ticket]} end,
        output: fn %{messages: messages} -> %{reply: messages |> List.last() |> Message.text()} end
      )
      |> BeamWeaver.Graph.add_edge(BeamWeaver.Graph.start(), :support)
      |> BeamWeaver.Graph.add_edge(:support, BeamWeaver.Graph.end_node())
      |> BeamWeaver.Graph.compile!()

    assert {:ok, events} = BeamWeaver.Graph.Compiled.stream_events(desk, %{ticket: "Where is A-1001?"})

    assert [%BeamWeaver.Stream.SubgraphRun{path: ["support"], status: :completed}] =
             BeamWeaver.Stream.Subgraphs.from_events(events)

    assert [%Envelope{namespace: ["support"]}] =
             Enum.filter(events, &match?(%Envelope{event: %Events.Debug{payload: %{type: :model_call_failed}}}, &1))
  end

  test "a subgraph whose model call fails, and fails again when retried, counts as failed" do
    script = start_script([cut_off("overloaded_error", "Overloaded"), cut_off("overloaded_error", "Overloaded")])
    :persistent_term.put({RetriedAgent, :script}, script)
    on_exit(fn -> :persistent_term.erase({RetriedAgent, :script}) end)

    desk =
      BeamWeaver.Graph.new()
      |> BeamWeaver.Graph.add_node(:support, RetriedAgent, input: fn %{ticket: ticket} -> %{messages: [ticket]} end)
      |> BeamWeaver.Graph.add_edge(BeamWeaver.Graph.start(), :support)
      |> BeamWeaver.Graph.add_edge(:support, BeamWeaver.Graph.end_node())
      |> BeamWeaver.Graph.compile!()

    assert {:ok, events} = BeamWeaver.Graph.Compiled.stream_events(desk, %{ticket: "Where is A-1001?"}, live: true)
    events = Enum.to_list(events)

    assert [%BeamWeaver.Stream.SubgraphRun{path: ["support"], status: :failed, error: "Overloaded"}] =
             BeamWeaver.Stream.Subgraphs.from_events(events)

    assert [%Envelope{namespace: [], event: %Events.Error{error: %Error{message: "Overloaded"}}}] =
             Enum.filter(events, &match?(%Envelope{event: %Events.Error{}}, &1))
  end

  test "a model call without streaming that ModelRetry retries sends the failed call's Debug event, not an Error" do
    overloaded =
      {529,
       BeamWeaver.JSON.encode!(%{
         "type" => "error",
         "error" => %{"type" => "overloaded_error", "message" => "Overloaded"}
       })}

    agent =
      agent(
        [overloaded, {200, BeamWeaver.JSON.encode!(message("It shipped on Monday."))}],
        [{ModelRetry, max_retries: 1}],
        stream: false
      )

    assert {:ok, events} = BeamWeaver.Agent.stream_events(agent, %{messages: ["Where is A-1001?"]}, live: true)
    events = Enum.to_list(events)

    refute Enum.any?(events, &match?(%Envelope{event: %Events.Error{}}, &1))

    assert [
             {:model_call_failed, %Error{type: :http_error, details: %{status: 529}}, "model"},
             {:answer, "It shipped on Monday."}
           ] =
             timeline(events)
  end

  # The model's text, the failed calls and the answer, in the order the
  # stream sends them.
  defp timeline(events) do
    Enum.flat_map(events, fn
      %Envelope{event: %Events.Token{text: text}} ->
        [{:token, text}]

      %Envelope{event: %Events.Debug{payload: %{type: :model_call_failed, error: error}}, node: node} ->
        [{:model_call_failed, error, node}]

      %Envelope{event: %Events.Message{message: %Message{role: :assistant} = message}} ->
        [{:answer, Message.text(message)}]

      _other ->
        []
    end)
  end

  defp agent(script, middleware, opts \\ [stream: true])

  defp agent(script, middleware, opts) when is_list(script), do: agent(start_script(script), middleware, opts)

  defp agent(script, middleware, opts) do
    {:ok, agent} =
      BeamWeaver.Agent.build(
        name: "orders",
        model: "anthropic:claude-haiku-4-5",
        model_opts: opts ++ model_opts(script),
        middleware: middleware
      )

    agent
  end

  defp start_script(replies) do
    {:ok, script} = Agent.start_link(fn -> replies end)
    script
  end

  defp model_opts(script), do: [api_key: "k", transport: Scripted, transport_opts: [script: script]]

  defp reply(text) do
    encode([
      %{"type" => "message_start", "message" => %{message("") | "content" => [], "stop_reason" => nil}},
      %{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "text", "text" => ""}},
      %{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "text_delta", "text" => text}},
      %{"type" => "content_block_stop", "index" => 0},
      %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}, "usage" => %{"output_tokens" => 5}},
      %{"type" => "message_stop"}
    ])
  end

  # A stream Anthropic breaks off after the start of the answer with an
  # `error` event.
  defp cut_off(type, message) do
    encode([
      %{"type" => "message_start", "message" => %{message("") | "content" => [], "stop_reason" => nil}},
      %{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "text", "text" => ""}},
      %{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "text_delta", "text" => "It shipped on"}},
      %{"type" => "error", "error" => %{"type" => type, "message" => message}}
    ])
  end

  defp message(text) do
    %{
      "id" => "msg_1",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-haiku-4-5",
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "stop_sequence" => nil,
      "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
    }
  end

  defp encode(events), do: Enum.map_join(events, &"event: #{&1["type"]}\ndata: #{BeamWeaver.JSON.encode!(&1)}\n\n")
end
