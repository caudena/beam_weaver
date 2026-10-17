defmodule BeamWeaver.Agent.SummarizationTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.Middleware.CompactConversation
  alias BeamWeaver.Agent.Middleware.Summarization
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph.Overwrite
  alias BeamWeaver.Models.FakeChatModel
  alias BeamWeaver.Models.Profile

  # A summary model with a small context window of its own.
  defp small_summary_model do
    %FakeChatModel{responses: ["The customer asked about orders."], profile: %Profile{max_input_tokens: 1_000}}
  end

  defp messages(count), do: for(n <- 1..count, do: Message.user("Question #{n}"))

  # 200 tokens per message, so 5 messages are 1,000 tokens.
  defp counter(messages), do: length(messages) * 200

  test "fractional triggers are taken of the agent model's window, not the summary model's" do
    middleware =
      Summarization.new(
        model: small_summary_model(),
        trigger: {:fraction, 0.5},
        max_input_tokens: 100_000,
        token_counter: &counter/1
      )

    assert Summarization.before_model(middleware, %{messages: messages(5)}, nil) == %{}

    middleware = %{middleware | max_input_tokens: 2_000, keep: {:messages, 1}}

    assert %{messages: %Overwrite{}} = Summarization.before_model(middleware, %{messages: messages(5)}, nil)
  end

  test "a fractional limit needs max_input_tokens" do
    assert_raise ArgumentError, ~r/need :max_input_tokens, the context window of the agent's model/, fn ->
      Summarization.new(model: small_summary_model(), trigger: {:fraction, 0.5})
    end
  end

  # A summary model that answers each call with the next result of its
  # script and sends the prompt it got to the test process.
  defmodule ScriptedSummaryModel do
    @behaviour BeamWeaver.Core.ChatModel

    defstruct [:parent, :script, profile: %Profile{max_input_tokens: 100_000}]

    @impl true
    def invoke(%__MODULE__{parent: parent, script: script}, [prompt], _opts) do
      send(parent, {:summary_prompt, Message.text(prompt)})

      case Agent.get_and_update(script, fn [result | rest] -> {result, if(rest == [], do: [result], else: rest)} end) do
        {:error, _error} = error -> error
        text -> {:ok, Message.assistant(text)}
      end
    end
  end

  defp scripted_summary_model(results) do
    {:ok, script} = Agent.start_link(fn -> results end)
    %ScriptedSummaryModel{parent: self(), script: script}
  end

  defp summarize_old_messages(middleware) do
    middleware = %{middleware | trigger: {:messages, 3}, keep: {:messages, 1}}
    Summarization.before_model(middleware, %{messages: messages(4)}, nil)
  end

  describe "a summary call that fails" do
    test "is tried again when retrying can help" do
      busy = BeamWeaver.Core.Error.new(:server_error, "Overloaded", %{status: 529, retryable: true})
      middleware = Summarization.new(model: scripted_summary_model([{:error, busy}, "The customer asked twice."]))

      assert %{messages: %Overwrite{value: [summary | _kept]}} = summarize_old_messages(middleware)
      assert Message.text(summary) == "Conversation summary:\nThe customer asked twice."
      assert_received {:summary_prompt, _first}
      assert_received {:summary_prompt, _second}
    end

    test "returns its error, keeping the thread, when retrying can't help" do
      unauthorized = BeamWeaver.Core.Error.new(:authentication, "Invalid API key", %{status: 401, retryable: false})
      middleware = Summarization.new(model: scripted_summary_model([{:error, unauthorized}]))

      assert {:error, ^unauthorized} = summarize_old_messages(middleware)
      assert_received {:summary_prompt, _prompt}
      refute_received {:summary_prompt, _again}
    end

    test "over the model's context window is tried once with the middle of the history cut out" do
      overflow = BeamWeaver.Core.Error.new(:context_overflow, "prompt is too long", %{status: 400, retryable: false})
      model = scripted_summary_model([{:error, overflow}, "Shorter summary."])
      middleware = Summarization.new(model: model, trigger: {:messages, 3}, keep: {:messages, 1})

      thread = [
        Message.user("Refund order A-1001. " <> String.duplicate("a", 400)),
        Message.assistant(String.duplicate("b", 400)),
        Message.user(String.duplicate("c", 400) <> " Also cancel A-1002."),
        Message.user("Thanks.")
      ]

      assert %{messages: %Overwrite{value: [summary | _kept]}} =
               Summarization.before_model(middleware, %{messages: thread}, nil)

      assert Message.text(summary) == "Conversation summary:\nShorter summary."

      assert_received {:summary_prompt, first}
      assert_received {:summary_prompt, second}
      assert String.length(second) < String.length(first)
      assert second =~ "Refund order A-1001."
      assert second =~ "[... middle of conversation omitted ...]"
      assert second =~ "Also cancel A-1002."
      refute second =~ String.duplicate("b", 400)
    end
  end

  describe ":summarizer" do
    test "writes the summary from the messages to summarize instead of a model" do
      summarizer = fn messages -> "#{length(messages)} questions about orders.\n" end
      middleware = Summarization.new(summarizer: summarizer)

      assert %{messages: %Overwrite{value: [summary, kept]}} = summarize_old_messages(middleware)
      assert Message.text(summary) == "Conversation summary:\n3 questions about orders."
      assert Message.text(kept) == "Question 4"
    end

    test "can fail with an error, and must return text" do
      error = BeamWeaver.Core.Error.new(:summary_service_down, "The summary service is down")

      assert {:error, ^error} =
               summarize_old_messages(Summarization.new(summarizer: fn _messages -> {:error, error} end))

      assert {:error, %BeamWeaver.Core.Error{type: :invalid_summary}} =
               summarize_old_messages(Summarization.new(summarizer: fn _messages -> :done end))
    end

    test "or a model is required" do
      assert_raise ArgumentError, ~r/needs :model or :summarizer/, fn -> Summarization.new([]) end
    end
  end

  # A scripted agent model with a 10,000-token context window.
  def agent_model do
    model = BeamWeaver.Models.init_chat_model!("fake:chat", responses: ["Answer."])
    %{model | profile: %{model.profile | max_input_tokens: 10_000}}
  end

  defmodule CompactingAgent do
    use BeamWeaver.Agent

    model BeamWeaver.Agent.SummarizationTest.agent_model()

    compact_conversation minimum_messages: 4,
                         keep_messages: 2,
                         summarization: [trigger: {:fraction, 0.5}, keep: {:messages, 3}]
  end

  defmodule ToolOnlyAgent do
    use BeamWeaver.Agent

    model "fake:chat", responses: ["Answer."]
    compact_conversation minimum_messages: 4, summarization: false
  end

  test "compact_conversation configures automatic summarization under summarization:" do
    # About 6,000 tokens: over half of the agent model's 10,000-token window.
    long_messages = for n <- 1..6, do: "Question #{n}: " <> String.duplicate("details ", 500)

    assert {:ok, result} = CompactingAgent.invoke(%{messages: long_messages})

    assert ["Conversation summary:" <> _, "Question 4:" <> _, "Question 5:" <> _, "Question 6:" <> _, "Answer."] =
             Enum.map(result.messages, &Message.text/1)
  end

  test "summarization: false keeps only the compact_conversation tool" do
    assert {:ok, result} = ToolOnlyAgent.invoke(%{messages: Enum.map(messages(25), &Message.text/1)})
    assert length(result.messages) == 26
  end

  test "the tool rejects automatic summarization settings" do
    assert_raise ArgumentError, ~r/doesn't take \[:trigger, :keep\]/, fn ->
      CompactConversation.new(model: small_summary_model(), trigger: {:messages, 40}, keep: {:messages, 10})
    end
  end

  # Answers "compacted(...)" to the compact_conversation tool's prompt and
  # "summarized(...)" to automatic summarization's, naming the [mN] tags of
  # the messages it summarized.
  defmodule TaggingSummaryModel do
    @behaviour BeamWeaver.Core.ChatModel

    alias BeamWeaver.Core.Message

    defstruct []

    @impl true
    def invoke(_model, [prompt], _opts) do
      text = Message.text(prompt)
      tags = ~r/\[(m\d+)\]/ |> Regex.scan(text) |> Enum.map(fn [_, tag] -> tag end) |> Enum.uniq()
      kind = if String.starts_with?(text, "Summarize this conversation concisely"), do: "compacted", else: "summarized"
      {:ok, Message.assistant("#{kind}(#{Enum.join(tags, ",")})")}
    end
  end

  defmodule Noop do
    use BeamWeaver.Tool

    name "noop"
    description "Does nothing."

    schema do
      field :n, :integer
    end

    @impl true
    def invoke(_tool, %{"n" => n}, _opts), do: {:ok, "noop #{n} done"}
  end

  defp model_calls do
    Stream.repeatedly(fn ->
      receive do
        {:fake_chat_model_call, messages, _opts} -> Enum.map(messages, &Message.text/1)
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(& &1)
  end

  test "with the default settings, a compaction keeps the newest messages and the request" do
    model = %FakeChatModel{parent: self(), responses: [FakeChatModel.tool_call("compact_conversation"), "Done."]}
    {:ok, agent} = BeamWeaver.Agent.build(model: model, compact_conversation: [model: %TaggingSummaryModel{}])

    assert {:ok, result} = BeamWeaver.Agent.invoke(agent, %{messages: for(i <- 0..18, do: "[m#{i}] note #{i}")})

    kept = for i <- 12..18, do: "[m#{i}] note #{i}"
    summary = "Conversation summary:\ncompacted(" <> Enum.map_join(0..11, ",", &"m#{&1}") <> ")"

    assert [^summary | rest] = Enum.map(result.messages, &Message.text/1)
    assert [_first_call, [_system, ^summary | second_call_rest]] = model_calls()
    assert Enum.take(rest, 7) == kept
    assert Enum.take(second_call_rest, 7) == kept
    assert List.last(rest) == "Done."
  end

  test "automatic summarization after a compaction keeps its newer summary" do
    model = %FakeChatModel{
      parent: self(),
      responses: [
        FakeChatModel.tool_call("compact_conversation"),
        FakeChatModel.tool_call("noop", %{"n" => 1}),
        FakeChatModel.tool_call("noop", %{"n" => 2}),
        "Done."
      ]
    }

    {:ok, agent} =
      BeamWeaver.Agent.build(
        model: model,
        tools: [Noop],
        compact_conversation: [
          model: %TaggingSummaryModel{},
          minimum_messages: 4,
          keep_messages: 2,
          summarization: [trigger: {:messages, 8}, keep: {:messages, 2}]
        ]
      )

    assert {:ok, result} = BeamWeaver.Agent.invoke(agent, %{messages: ["[m0] hello", "[m1] more", "[m2] the task"]})

    assert [_first, second, _third, fourth] = model_calls()
    assert Enum.slice(second, 1, 2) == ["Conversation summary:\ncompacted(m0,m1)", "[m2] the task"]
    assert Enum.at(fourth, 1) == "Conversation summary:\nsummarized(m2)"
    assert hd(result.messages) |> Message.text() == "Conversation summary:\nsummarized(m2)"
  end

  test "a compaction is applied once, and dropped when the thread changed after the tool ran" do
    middleware = CompactConversation.new(model: %TaggingSummaryModel{}, minimum_messages: 4, keep_messages: 2)
    [tool] = CompactConversation.tools(middleware)
    messages = for i <- 0..4, do: Message.user("[m#{i}] note", id: "id-#{i}")

    assert {:ok, %BeamWeaver.Graph.Command{update: %{_summarization_event: event, messages: [tool_message]}}} =
             BeamWeaver.Core.Tool.invoke(tool, %{state: %{messages: messages}, tool_call_id: "call-1"})

    state = %{messages: messages ++ [tool_message], _summarization_event: event}

    assert %{messages: %Overwrite{value: [summary | kept]}, _summarization_event: nil} =
             CompactConversation.before_model(middleware, state, nil)

    assert Message.text(summary) == "Conversation summary:\ncompacted(m0,m1,m2)"
    assert Enum.map(kept, & &1.id) == ["id-3", "id-4", tool_message.id]

    summarized = [Message.user("Conversation summary:\nsummarized(m0,m1,m2,m3)"), List.last(messages), tool_message]

    assert CompactConversation.before_model(middleware, %{state | messages: summarized}, nil) ==
             %{_summarization_event: nil}
  end

  test "a compaction recorded before a pause applies once after the run resumes" do
    assert_compaction_survives_a_pause(BeamWeaver.Checkpoint.ETS.new(), "compact-pause")
  end

  # The model compacts and the run pauses after the tools step, in which the
  # tool recorded the compaction. The compaction comes back from the
  # checkpoint, applies before the next model call, and only once.
  def assert_compaction_survives_a_pause(saver, thread_id) do
    model = %FakeChatModel{
      parent: self(),
      responses: [FakeChatModel.tool_call("compact_conversation"), "Done.", "Still done."]
    }

    {:ok, agent} =
      BeamWeaver.Agent.build(
        model: model,
        compact_conversation: [
          model: %TaggingSummaryModel{},
          minimum_messages: 4,
          keep_messages: 2,
          summarization: false
        ]
      )

    config = %{"configurable" => %{"thread_id" => thread_id}}
    opts = [checkpointer: saver, config: config, interrupt_after: [:tools]]
    summary = "Conversation summary:\ncompacted(m0,m1,m2,m3)"
    input = %{messages: for(i <- 0..4, do: "[m#{i}] note #{i}")}

    assert {:interrupted, _interrupt} = BeamWeaver.Agent.invoke(agent, input, opts)
    assert %{cutoff_index: 4, summary_message: %Message{}} = pending_compaction(saver, config)

    assert {:ok, result} = BeamWeaver.Agent.resume(agent, nil, opts)
    assert [_first_call, [_system, ^summary, "[m4] note 4" | _rest]] = model_calls()

    assert [^summary, "[m4] note 4", "", "Conversation compacted." <> _, "Done."] =
             Enum.map(result.messages, &Message.text/1)

    assert pending_compaction(saver, config) == nil

    assert {:ok, result} = BeamWeaver.Agent.invoke(agent, %{messages: ["[m5] note 5"]}, opts)

    assert [^summary, "[m4] note 4", "", "Conversation compacted." <> _, "Done.", "[m5] note 5", "Still done."] =
             Enum.map(result.messages, &Message.text/1)
  end

  defp pending_compaction(saver, config) do
    %{checkpoint: %{"channel_values" => values}} = BeamWeaver.Checkpoint.get_tuple(saver, config)
    Map.get(values, :_summarization_event)
  end

  defp xai_summary_model do
    BeamWeaver.XAI.ChatModel.new(
      model: "grok-4.3",
      api_key: "xai-test",
      transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
      transport_opts: [
        parent: self(),
        body: %{
          "id" => "resp_1",
          "status" => "completed",
          "output" => [
            %{
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "output_text", "text" => "The customer asked about orders."}]
            }
          ]
        }
      ]
    )
  end

  test "summaries work with a model whose API has no request metadata, such as xAI" do
    summarization = Summarization.new(model: xai_summary_model(), trigger: {:messages, 3}, keep: {:messages, 1})

    assert %{messages: %Overwrite{value: [summary, _kept]}} =
             Summarization.before_model(summarization, %{messages: messages(3)}, nil)

    assert Message.text(summary) == "Conversation summary:\nThe customer asked about orders."
    assert_received {:fake_transport_request, %{json: body}}
    refute Map.has_key?(body, "metadata")

    compaction = CompactConversation.new(model: xai_summary_model(), minimum_messages: 3, keep_messages: 1)
    [tool] = CompactConversation.tools(compaction)

    assert {:ok, %BeamWeaver.Graph.Command{update: %{_summarization_event: %{summary_message: compacted}}}} =
             BeamWeaver.Core.Tool.invoke(tool, %{state: %{messages: messages(3)}, tool_call_id: "call-1"})

    assert Message.text(compacted) == "Conversation summary:\nThe customer asked about orders."
    assert_received {:fake_transport_request, %{json: body}}
    refute Map.has_key?(body, "metadata")
  end
end

defmodule BeamWeaver.Agent.CompactConversationSQLiteTest do
  # The SQLite repo has a single connection, shared with other suites.
  use ExUnit.Case, async: false

  import BeamWeaver.Agent.SummarizationTest, only: [assert_compaction_survives_a_pause: 2]

  alias BeamWeaver.Test.LiveSQLite
  alias BeamWeaver.Test.SQLiteRepo

  @moduletag :capture_log

  test "a compaction recorded before a pause survives a checkpointer that stores JSON" do
    checkpoints = LiveSQLite.unique_table("bw_compact_checkpoints")
    writes = LiveSQLite.unique_table("bw_compact_writes")

    version =
      LiveSQLite.migrate(
        repo: SQLiteRepo,
        adapters: [{:checkpoint, checkpoints_table: checkpoints, writes_table: writes}]
      )

    on_exit(fn ->
      LiveSQLite.drop_tables([writes, checkpoints])
      LiveSQLite.clear_migration(version)
    end)

    saver = BeamWeaver.Checkpoint.Ecto.new(repo: SQLiteRepo, checkpoints_table: checkpoints, writes_table: writes)
    assert_compaction_survives_a_pause(saver, "compact-pause-sqlite")
  end
end
