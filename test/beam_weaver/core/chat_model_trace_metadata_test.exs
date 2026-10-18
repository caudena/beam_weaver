defmodule BeamWeaver.Core.ChatModelTraceMetadataTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Tracing.Run

  defmodule Exporter do
    @behaviour BeamWeaver.Tracing.Exporter

    @impl true
    def export(event, run, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:trace_export, event, run})
      :ok
    end
  end

  test "trace_metadata: adds its entries to the model call's trace run" do
    model = BeamWeaver.Models.init_chat_model!("fake:chat", responses: ["Summary."])

    assert {:ok, %Message{content: "Summary."}} =
             ChatModel.invoke(model, [Message.user("Summarize this conversation")],
               trace_metadata: %{source: :summarization},
               exporter: Exporter,
               exporter_opts: [test_pid: self()]
             )

    assert_receive {:trace_export, :ok, %Run{kind: :model, metadata: metadata}}
    assert metadata.source == :summarization
    refute Map.has_key?(metadata.invocation_params, :trace_metadata)
  end

  test "traces a reply whose transport metadata isn't a map without a request id" do
    model = BeamWeaver.Models.init_chat_model!("fake:chat", responses: ["Done."])
    reply = Message.assistant("Done.", response_metadata: %{transport: "x"})
    opts = [exporter: Exporter, exporter_opts: [test_pid: self()]]

    assert {:ok, ^reply} =
             ChatModel.trace_call(model, [Message.user("Summarize this conversation")], opts, fn -> {:ok, reply} end)

    assert_receive {:trace_export, :ok, %Run{kind: :model, metadata: metadata}}
    refute Map.has_key?(metadata, :request_id)
  end

  test "every built-in chat model leaves trace_metadata: out of its request" do
    models = [
      BeamWeaver.OpenAI.chat_model(model: "gpt-5.4-mini"),
      BeamWeaver.OpenAI.chat_completions_model(model: "gpt-5.4-mini"),
      BeamWeaver.Anthropic.ChatModel.new(model: "claude-haiku-4-5"),
      BeamWeaver.Google.ChatModel.new(model: "gemini-3.5-flash"),
      BeamWeaver.XAI.ChatModel.new(model: "grok-4.3"),
      BeamWeaver.XAI.ChatCompletionsModel.new(model: "grok-4.3"),
      BeamWeaver.DeepSeek.ChatModel.new(model: "deepseek-flash"),
      BeamWeaver.DeepSeek.ResponsesModel.new(model: "deepseek-flash"),
      BeamWeaver.Moonshot.ChatModel.new(model: "kimi-k2.6"),
      BeamWeaver.ZAI.ChatModel.new(model: "glm-5.2")
    ]

    for model <- models do
      assert {:ok, body} =
               model.__struct__.request_body(model, [Message.user("Summarize this conversation")],
                 trace_metadata: %{source: :summarization}
               )

      refute inspect(body) =~ "summarization", "#{inspect(model.__struct__)} sent the trace metadata"
    end
  end
end
