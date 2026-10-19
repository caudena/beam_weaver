defmodule BeamWeaver.Agent.CompactConversationTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.Middleware.CompactConversation
  alias BeamWeaver.Agent.Middleware.Subagents
  alias BeamWeaver.Agent.Middleware.Summarization
  alias BeamWeaver.Agent.Subagent.Compiled
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Models.FakeChatModel

  # A summary model that answers each call with the next result of its
  # script and sends the prompt it got to the test process.
  defmodule ScriptedSummaryModel do
    @behaviour BeamWeaver.Core.ChatModel

    defstruct [:parent, :script]

    @impl true
    def invoke(%__MODULE__{parent: parent, script: script}, [prompt], _opts) do
      send(parent, {:summary_prompt, Message.text(prompt)})

      case Agent.get_and_update(script, fn [result | rest] -> {result, rest} end) do
        {:error, _error} = error -> error
        text -> {:ok, Message.assistant(text)}
      end
    end
  end

  defp scripted_summary_model(results) do
    script = start_supervised!({Agent, fn -> results end})
    %ScriptedSummaryModel{parent: self(), script: script}
  end

  defp compaction(opts), do: CompactConversation.new([minimum_messages: 3, keep_messages: 1] ++ opts)

  # Runs the tool on `messages` and returns its state update.
  defp compact(middleware, messages) do
    [tool] = CompactConversation.tools(middleware)

    assert {:ok, %Command{update: update}} =
             Tool.invoke(tool, %{state: %{messages: messages}, tool_call_id: "call-1"})

    update
  end

  defp notes(count), do: for(n <- 1..count, do: Message.user("Note #{n}"))

  describe "a summary call that fails" do
    test "is tried again when retrying can help" do
      busy = Error.new(:server_error, "Overloaded", %{status: 529, retryable: true})
      middleware = compaction(model: scripted_summary_model([{:error, busy}, "Three notes."]))

      assert %{_summarization_event: %{summary_message: summary}} = compact(middleware, notes(4))
      assert "Conversation summary:\nThree notes." <> _ = Message.text(summary)
      assert_received {:summary_prompt, _first}
      assert_received {:summary_prompt, _second}
    end

    test "over the model's context window is tried once with the middle of the history cut out" do
      overflow = Error.new(:context_overflow, "prompt is too long", %{status: 400, retryable: false})
      middleware = compaction(model: scripted_summary_model([{:error, overflow}, "Shorter summary."]))

      thread = [
        Message.user("Refund order A-1001. " <> String.duplicate("a", 400)),
        Message.assistant(String.duplicate("b", 400)),
        Message.user(String.duplicate("c", 400) <> " Also cancel A-1002."),
        Message.user("Thanks.")
      ]

      assert %{_summarization_event: %{summary_message: summary}} = compact(middleware, thread)
      assert "Conversation summary:\nShorter summary." <> _ = Message.text(summary)

      assert_received {:summary_prompt, first}
      assert_received {:summary_prompt, second}
      assert String.length(second) < String.length(first)
      assert second =~ "Refund order A-1001."
      assert second =~ "[... middle of conversation omitted ...]"
      assert second =~ "Also cancel A-1002."
    end

    test "still failing leaves the thread as it was" do
      unauthorized = Error.new(:authentication, "Invalid API key", %{status: 401, retryable: false})
      middleware = compaction(model: scripted_summary_model([{:error, unauthorized}]))

      assert %{messages: [tool_message]} = update = compact(middleware, notes(4))
      refute Map.has_key?(update, :_summarization_event)
      assert Message.text(tool_message) == "Compaction failed: Invalid API key"
      assert tool_message.metadata.status == "error"
    end
  end

  describe ":summarizer" do
    test "writes the summary instead of a model" do
      middleware = compaction(summarizer: fn messages -> "#{length(messages)} notes about orders.\n" end)

      assert %{_summarization_event: %{summary_message: summary}} = compact(middleware, notes(4))
      assert "Conversation summary:\n3 notes about orders.\n\n" <> _ = Message.text(summary)
    end

    test "can fail with an error, or by raising" do
      down = Error.new(:summary_service_down, "The summary service is down")

      for summarizer <- [fn _messages -> {:error, down} end, fn _messages -> raise "no summaries today" end] do
        assert %{messages: [tool_message]} = compact(compaction(summarizer: summarizer), notes(4))
        assert Message.text(tool_message) =~ ~r/^Compaction failed: (The summary service is down|no summaries today)$/
      end
    end

    test "or a model is required" do
      assert_raise ArgumentError, ~r/needs :model or :summarizer/, fn -> CompactConversation.new([]) end
    end

    test "is taken by the compact_conversation declaration" do
      model = %FakeChatModel{responses: [FakeChatModel.tool_call("compact_conversation"), "Done."]}

      {:ok, agent} =
        BeamWeaver.Agent.build(
          model: model,
          compact_conversation: [
            summarizer: fn messages -> "#{length(messages)} notes." end,
            minimum_messages: 4,
            keep_messages: 2,
            summarization: false
          ]
        )

      assert {:ok, result} = BeamWeaver.Agent.invoke(agent, %{messages: Enum.map(notes(5), &Message.text/1)})
      assert "Conversation summary:\n4 notes." <> _ = result.messages |> hd() |> Message.text()
    end
  end

  test "the declaration's automatic summaries cover all the old messages, unless summarization: trims them" do
    {:ok, agent} =
      BeamWeaver.Agent.build(
        model: %FakeChatModel{response: "Done."},
        compact_conversation: true,
        subagents: [BeamWeaver.Agent.GeneralPurposeSubagentProfile.new()]
      )

    summarization = fn middleware -> Enum.find(middleware, &match?(%Summarization{}, &1)) end
    assert %Summarization{trim_tokens_to_summarize: nil} = summarization.(agent.spec.middleware)

    subagents = Enum.find(agent.spec.middleware, &match?(%Subagents{}, &1))

    assert {:ok, %Compiled{agent: %BeamWeaver.Agent.Built{spec: spec}}} =
             Subagents.build_subagent(subagents, "general-purpose")

    assert %Summarization{trim_tokens_to_summarize: nil} = summarization.(spec.middleware)

    {:ok, agent} =
      BeamWeaver.Agent.build(
        model: %FakeChatModel{response: "Done."},
        compact_conversation: [summarization: [trim_tokens_to_summarize: 2_000]]
      )

    assert %Summarization{trim_tokens_to_summarize: 2_000} = summarization.(agent.spec.middleware)
    assert %Summarization{trim_tokens_to_summarize: 4_000} = Summarization.new(model: %FakeChatModel{})
  end

  test "the declaration's summarizer also writes automatic summaries and those of subagents" do
    summarizer = fn messages -> "#{length(messages)} notes." end
    researcher = %{name: "researcher", description: "Researches.", model: "fake:chat", base_middleware: [:deepagents]}

    {:ok, agent} =
      BeamWeaver.Agent.build(
        model: %FakeChatModel{response: "Done."},
        compact_conversation: [summarizer: summarizer],
        subagents: [researcher]
      )

    summarization = fn middleware -> Enum.find(middleware, &match?(%Summarization{}, &1)) end
    assert %Summarization{summarizer: ^summarizer} = summarization.(agent.spec.middleware)

    subagents = Enum.find(agent.spec.middleware, &match?(%Subagents{}, &1))

    for name <- ["general-purpose", "researcher"] do
      assert {:ok, %Compiled{agent: %BeamWeaver.Agent.Built{spec: spec}}} = Subagents.build_subagent(subagents, name)
      assert %Summarization{summarizer: ^summarizer} = summarization.(spec.middleware)
    end
  end

  describe "the prompt" do
    # The system prompt of the agent's first model call.
    defp system_prompt(compact_conversation) do
      {:ok, agent} =
        BeamWeaver.Agent.build(
          model: %FakeChatModel{parent: self(), response: "Hello."},
          system_prompt: "You are Acme's support agent.",
          compact_conversation: compact_conversation
        )

      assert {:ok, _result} = BeamWeaver.Agent.invoke(agent, %{messages: ["Hi."]})
      assert_received {:fake_chat_model_call, [%Message{role: :system} = system | _rest], _opts}
      Message.text(system)
    end

    test "gets no section about the tool, unless system_prompt: gives one" do
      assert system_prompt(true) == "You are Acme's support agent."

      assert system_prompt(system_prompt: "Compact when the user changes the subject.") ==
               "You are Acme's support agent.\n\nCompact when the user changes the subject."
    end

    test "leaves it to the tool's description to say when to compact" do
      [tool] = CompactConversation.tools(compaction(model: %FakeChatModel{}))
      assert Tool.description(tool) =~ "new task"
      assert Tool.description(tool) =~ "no longer need"
    end
  end

  test "the summary says where the messages it replaces were saved" do
    middleware = compaction(model: scripted_summary_model(["Order A-1001 shipped."]))

    assert %{_summarization_event: %{summary_message: summary, file_path: path}, files: files} =
             compact(middleware, notes(4))

    assert "/conversation_history/" <> _ = path
    assert files[path].content =~ "Note 3"

    assert Message.text(summary) ==
             "Conversation summary:\nOrder A-1001 shipped.\n\n" <>
               "The messages this summary replaces were saved in full to #{path}."
  end
end
