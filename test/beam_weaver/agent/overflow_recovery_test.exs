defmodule BeamWeaver.Agent.OverflowRecoveryTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.Middleware.OverflowRecovery
  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Models.FakeChatModel

  # Rejects any request with a message over 10,000 characters, the way a
  # provider rejects a request that is too long for the model, with
  # `overflow` as its error.
  defmodule SmallWindowModel do
    @behaviour BeamWeaver.Core.ChatModel

    defstruct overflow: {:context_overflow, "prompt is too long"}

    @impl true
    def invoke(%__MODULE__{overflow: {type, message}}, messages, opts) do
      send(opts[:context].parent, {:model_call, messages})

      cond do
        Enum.any?(messages, &(String.length(Message.text(&1)) > 10_000)) ->
          {:error, Error.new(type, message)}

        match?(%Message{role: :user}, List.last(messages)) and length(messages) == 1 ->
          {:ok, Message.assistant("", tool_calls: [%{id: "call_1", name: "order_history", args: %{}}])}

        true ->
          {:ok, Message.assistant("Ada has 5,000 orders.")}
      end
    end
  end

  defmodule OrderHistory do
    use BeamWeaver.Tool

    name "order_history"
    description "Export all orders of a customer as CSV."

    schema do
    end

    @impl true
    def invoke(_tool, _input, _opts) do
      rows = for n <- 1..5_000, do: "A-#{1000 + n},shipped,2026-05-04\n"
      {:ok, IO.iodata_to_binary(["order_id,status,shipped_on\n" | rows])}
    end
  end

  defmodule SupportAgent do
    use BeamWeaver.Agent

    model %SmallWindowModel{}
    tools [OrderHistory]
    overflow_recovery true
  end

  # A proxy in front of the provider passes its overflow on as a bad request,
  # in its own words.
  defmodule ProxiedSupportAgent do
    use BeamWeaver.Agent

    model %SmallWindowModel{
      overflow: {:invalid_request, "litellm.ContextWindowExceededError: litellm.BadRequestError: prompt too long"}
    }

    tools [OrderHistory]
    overflow_recovery true
  end

  defp invoke(agent \\ SupportAgent, input, opts),
    do: agent.invoke(input, Keyword.put(opts, :context, %{parent: self()}))

  test "the clipped result is saved in the thread, so the next call doesn't overflow" do
    opts = [checkpointer: Checkpoint.ETS.new(), config: %{"configurable" => %{"thread_id" => "overflow"}}]

    assert {:ok, first} = invoke(%{messages: ["How many orders does Ada have?"]}, opts)
    assert List.last(first.messages) |> Message.text() == "Ada has 5,000 orders."

    tool_message = Enum.find(first.messages, &(&1.role == :tool))
    assert Message.text(tool_message) =~ "saved in the filesystem at this path: /large_tool_results/call_1"
    assert first.files["/large_tool_results/call_1"].content =~ "A-6000,shipped"

    flush_model_calls()

    assert {:ok, second} = invoke(%{messages: ["Thanks!"]}, opts)
    assert List.last(second.messages) |> Message.text() == "Ada has 5,000 orders."
    assert [_one_call] = flush_model_calls()
  end

  test "an overflow that only its message tells apart is recovered from too" do
    assert {:ok, result} = invoke(ProxiedSupportAgent, %{messages: ["How many orders does Ada have?"]}, [])
    assert List.last(result.messages) |> Message.text() == "Ada has 5,000 orders."
    assert result.files["/large_tool_results/call_1"].content =~ "A-6000,shipped"
  end

  # Fails as a provider does for a request too long for the model when a
  # message after the system prompt is over 10,000 characters or there are
  # more than `max_messages` of them; otherwise `model` answers.
  defmodule WindowModel do
    @behaviour BeamWeaver.Core.ChatModel

    defstruct [:model, max_messages: 100]

    @impl true
    def invoke(%__MODULE__{} = window, messages, opts) do
      sent = Enum.reject(messages, &(&1.role == :system))
      send(opts[:context].parent, {:model_call, sent})

      if length(sent) > window.max_messages or Enum.any?(sent, &(String.length(Message.text(&1)) > 10_000)),
        do: {:error, Error.new(:context_overflow, "prompt is too long")},
        else: FakeChatModel.invoke(window.model, messages, opts)
    end
  end

  # The same agent with automatic summarization declared, and with a
  # `Summarization` of its own, which runs after the declared overflow
  # recovery instead of before it.
  defp summarizing_agents(max_messages) do
    script = [FakeChatModel.tool_call("order_history"), "Ada has 5,000 orders."]
    model = %WindowModel{max_messages: max_messages, model: %FakeChatModel{responses: script}}
    summary_model = %FakeChatModel{parent: self(), response: "Ada asked about her orders."}
    summarization = [trigger: {:messages, 50}, keep: {:messages, 2}]

    for declaration <- [
          [compact_conversation: [model: summary_model, summarization: summarization]],
          [middleware: [{BeamWeaver.Agent.Middleware.Summarization, [model: summary_model] ++ summarization}]]
        ] do
      {:ok, agent} =
        BeamWeaver.Agent.build([model: model, tools: [OrderHistory], overflow_recovery: true] ++ declaration)

      agent
    end
  end

  defp summary_prompts do
    receive do
      {:fake_chat_model_call, [prompt], _opts} -> [Message.text(prompt) | summary_prompts()]
    after
      0 -> []
    end
  end

  describe "with automatic summarization" do
    test "the tool results are clipped first, and the history isn't summarized when that is enough" do
      for agent <- summarizing_agents(100) do
        assert {:ok, result} =
                 BeamWeaver.Agent.invoke(agent, %{messages: ["How many orders does Ada have?"]},
                   context: %{parent: self()}
                 )

        assert List.last(result.messages) |> Message.text() == "Ada has 5,000 orders."
        assert [_tool_call, _overflow, _clipped] = flush_model_calls()
        assert summary_prompts() == []
      end
    end

    test "the history is summarized once clipping isn't enough, and its retry keeps the results clipped" do
      for agent <- summarizing_agents(4) do
        input = %{messages: ["Hi, I'm Ada.", "I ordered a lot.", "Over the years.", "How many orders do I have?"]}
        assert {:ok, result} = BeamWeaver.Agent.invoke(agent, input, context: %{parent: self()})

        assert [_tool_call, _overflow, _clipped_overflow, summarized] = flush_model_calls()
        assert [_one_summary] = summary_prompts()

        assert ["Conversation summary:\nAda asked about her orders.", "", clipped, "Ada has 5,000 orders."] =
                 Enum.map(result.messages, &Message.text/1)

        assert Enum.map(summarized, &Message.text/1) == Enum.take(Enum.map(result.messages, &Message.text/1), 3)
        assert clipped =~ "saved in the filesystem at this path: /large_tool_results/"
        assert [%{content: content}] = Map.values(result.files)
        assert content =~ "A-6000,shipped"
      end
    end
  end

  describe "given a summarization" do
    defp history do
      rows = for n <- 1..5_000, do: "A-#{1000 + n},shipped\n"

      [
        Message.user("Hi, I'm Ada.", id: "m1"),
        Message.user("I ordered a lot.", id: "m2"),
        Message.assistant("", id: "m3", tool_calls: [%{id: "call_1", name: "order_history", args: %{}}]),
        Message.tool(IO.iodata_to_binary(rows), id: "m4", tool_call_id: "call_1", name: "order_history")
      ]
    end

    # Sends the history through `middleware` to a model that takes at most
    # `max_messages` messages of at most 10,000 characters each.
    defp send_history(middleware, max_messages) do
      parent = self()
      request = %BeamWeaver.Agent.ModelRequest{messages: history(), state: %{messages: history()}}

      OverflowRecovery.wrap_model_call(middleware, request, fn request ->
        send(parent, {:sent, Enum.map(request.messages, &Message.text/1)})

        if length(request.messages) > max_messages or
             Enum.any?(request.messages, &(String.length(Message.text(&1)) > 10_000)),
           do: {:error, Error.new(:context_overflow, "prompt is too long")},
           else: {:ok, %BeamWeaver.Agent.ModelResponse{messages: [Message.assistant("Ada has 5,000 orders.")]}}
      end)
    end

    defp sent do
      receive do
        {:sent, texts} -> [texts | sent()]
      after
        0 -> []
      end
    end

    defp recovery do
      summarization =
        BeamWeaver.Agent.Middleware.Summarization.new(
          summarizer: fn _messages -> "Ada asked about her orders." end,
          keep: {:messages, 2}
        )

      OverflowRecovery.new(summarization: summarization)
    end

    test "summarizes the clipped request when it still overflows, and sends it once more" do
      assert %BeamWeaver.Agent.ExtendedModelResponse{} = send_history(recovery(), 3)

      assert [_overflow, [_, _, _, clipped] = _clipped_overflow, summarized] = sent()
      assert summarized == ["Conversation summary:\nAda asked about her orders.", "", clipped]
      assert clipped =~ "saved in the filesystem at this path: /large_tool_results/call_1"
    end

    test "doesn't summarize when clipping is enough" do
      refute match?({:error, _error}, send_history(recovery(), 4))
      assert [_overflow, _clipped] = sent()
    end

    test "returns the error when the summarized request overflows too" do
      assert {:error, %Error{type: :context_overflow}} = send_history(recovery(), 2)
      assert [_overflow, _clipped_overflow, _summarized_overflow] = sent()
    end
  end

  defmodule StructuredOverflowModel do
    # Answers the tool loop, and is over its context window in the
    # structured-response call, which is offered only the schema's tool.
    @behaviour BeamWeaver.Core.ChatModel

    defstruct []

    @impl true
    def invoke(_model, _messages, opts) do
      if "order_history" in Enum.map(Keyword.get(opts, :tools, []), &BeamWeaver.Core.Tool.name/1),
        do: {:ok, Message.assistant("Ada has 5,000 orders.")},
        else: {:error, Error.new(:context_overflow, "prompt is too long")}
    end
  end

  defmodule Triage do
    use BeamWeaver.Schema

    field :topic, :string
  end

  test "the structured-response call only clips: automatic summarization isn't part of it" do
    summary_model = %FakeChatModel{parent: self(), response: "Ada asked about her orders."}

    {:ok, agent} =
      BeamWeaver.Agent.build(
        model: %StructuredOverflowModel{},
        tools: [OrderHistory],
        response_format: BeamWeaver.Agent.StructuredOutput.tool(Triage),
        overflow_recovery: true,
        compact_conversation: [model: summary_model, summarization: [trigger: {:messages, 50}, keep: {:messages, 1}]]
      )

    input = %{messages: ["Hi, I'm Ada.", "I ordered a lot.", "How many orders do I have?"]}
    assert {:error, %Error{type: :context_overflow}} = BeamWeaver.Agent.invoke(agent, input)
    assert summary_prompts() == []
  end

  test "an agent with both hands its summarization to overflow recovery, and only that handles overflows" do
    for agent <- summarizing_agents(4) do
      assert [%{on_overflow: false} = summarization] =
               for(%BeamWeaver.Agent.Middleware.Summarization{} = entry <- agent.spec.middleware, do: entry)

      assert [%{summarization: ^summarization}] = for(%OverflowRecovery{} = entry <- agent.spec.middleware, do: entry)
    end
  end

  test "keep defaults to a 5,000-token threshold and rejects a message count" do
    assert %OverflowRecovery{keep: {:tokens, 5_000}} = OverflowRecovery.new()

    assert_raise ArgumentError, ~r/keep must be \{:tokens, n\} or \{:fraction, f\}/, fn ->
      OverflowRecovery.new(keep: {:messages, 8})
    end
  end

  defp flush_model_calls do
    receive do
      {:model_call, messages} -> [messages | flush_model_calls()]
    after
      0 -> []
    end
  end

  test "clipped results without a tool call id are saved under different names" do
    messages = [
      Message.assistant("tool calls"),
      Message.tool(Enum.map_join(1..12, "\n", &"first #{&1}"), name: "expensive_tool"),
      Message.tool(Enum.map_join(1..12, "\n", &"second #{&1}"), name: "expensive_tool")
    ]

    assert %OverflowRecovery{clipped?: true, files_update: files} =
             OverflowRecovery.clip_tail(messages, BeamWeaver.Filesystem.State.new(), keep: {:tokens, 1}, state: %{})

    assert map_size(files) == 2
  end
end
