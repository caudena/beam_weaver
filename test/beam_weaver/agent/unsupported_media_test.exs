defmodule BeamWeaver.Agent.UnsupportedMediaTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent
  alias BeamWeaver.Agent.Middleware.ModelFallback
  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Models.FakeChatModel
  alias BeamWeaver.Models.Profile
  alias BeamWeaver.Models.ProfileRegistry

  @png Base.encode64(<<137, 80, 78, 71, 13, 10, 26, 10>>)
  @pdf Base.encode64("%PDF-1.4\n%%EOF")

  # Adds an image to every request, as an agent's own middleware might.
  defmodule AttachPhoto do
    use BeamWeaver.Agent.Middleware

    def wrap_model_call(_middleware, %ModelRequest{} = request, handler) do
      photo = Message.user([ContentBlock.image(data: Base.encode64("photo"), mime_type: "image/jpeg")])
      handler.(ModelRequest.override(request, messages: request.messages ++ [photo]))
    end
  end

  # Middleware intentionally trusts only registered profiles. Select by the
  # capability under test, without depending on a provider's current lineup.
  defp media_profile(image?, pdf?),
    do: Enum.find(ProfileRegistry.all(), &(&1.image_inputs == image? and &1.pdf_inputs == pdf?))

  defp text_only, do: media_profile(false, false)

  defp model(profile, opts \\ []),
    do: struct!(FakeChatModel, Keyword.merge([responses: ["Done."], parent: self(), profile: profile], opts))

  # A thread whose last tool results hold an image and a PDF.
  defp media_thread do
    calls = [
      %{id: "call_1", name: "read_file", args: %{"file_path" => "/chart.png"}},
      %{id: "call_2", name: "read_file", args: %{"file_path" => "/report.pdf"}}
    ]

    [
      Message.user("Look at the chart and the report"),
      Message.assistant("", tool_calls: calls),
      Message.tool(
        [
          ContentBlock.text("File /chart.png is an image (8 bytes)."),
          ContentBlock.image(data: @png, mime_type: "image/png")
        ],
        tool_call_id: "call_1",
        name: "read_file"
      ),
      Message.tool(
        [
          ContentBlock.text("File /report.pdf is a PDF (15 bytes)."),
          ContentBlock.file(data: @pdf, mime_type: "application/pdf", filename: "report.pdf")
        ],
        tool_call_id: "call_2",
        name: "read_file"
      ),
      Message.user("What do they show?")
    ]
  end

  defp run(agent_opts, messages \\ media_thread()) do
    {:ok, agent} = Agent.build(agent_opts)
    Agent.invoke(agent, %{messages: messages})
  end

  defp received_messages do
    assert_received {:fake_chat_model_call, messages, _opts}
    messages
  end

  defp tool_contents(messages), do: for(%Message{role: :tool, content: content} <- messages, do: content)

  test "a text-only model gets a notice for each image and PDF in the thread" do
    assert {:ok, result} = run(model: model(text_only()))

    assert tool_contents(received_messages()) == [
             [
               ContentBlock.text("File /chart.png is an image (8 bytes)."),
               ContentBlock.text("[An image was left out: this model doesn't take images.]")
             ],
             [
               ContentBlock.text("File /report.pdf is a PDF (15 bytes)."),
               ContentBlock.text("[report.pdf was left out: this model doesn't take PDFs.]")
             ]
           ]

    # The thread keeps the media, for a later model that takes it.
    assert [[_text, %ContentBlock.Image{}], [_notice, %ContentBlock.File{}]] = tool_contents(result.messages)
  end

  test "a model whose built-in profile takes images and PDFs gets them" do
    assert {:ok, _result} = run(model: model(media_profile(true, true)))

    assert [[_text, %ContentBlock.Image{}], [_notice, %ContentBlock.File{}]] = tool_contents(received_messages())
  end

  test "a profile declared by hand, or none, keeps the media" do
    for profile <- [Profile.new(%{max_input_tokens: 100_000, tool_calling: true}), %{text_only() | name: "Mine"}, nil] do
      assert {:ok, _result} = run(model: model(profile))
      assert [[_text, %ContentBlock.Image{}], [_notice, %ContentBlock.File{}]] = tool_contents(received_messages())
    end
  end

  test "the fake chat model takes images and PDFs" do
    assert {:ok, _result} =
             run(model: BeamWeaver.Models.init_chat_model!("fake:chat", responses: ["Done."], parent: self()))

    assert [[_text, %ContentBlock.Image{}], [_notice, %ContentBlock.File{}]] = tool_contents(received_messages())
  end

  test "it runs after the agent's own middleware" do
    assert {:ok, _result} = run([model: model(text_only()), middleware: [AttachPhoto]], ["Hello"])

    assert [%Message{content: "Hello"}, %Message{content: [notice]}] = received_messages()
    assert notice == ContentBlock.text("[An image was left out: this model doesn't take images.]")
  end

  test "a fallback that can't take images gets the notice" do
    primary = model(media_profile(true, true), error: Error.new(:provider_error, "Service unavailable"))
    fallback = model(text_only(), responses: ["The fallback answered."])

    assert {:ok, result} = run(model: primary, middleware: [{ModelFallback, fallbacks: [fallback]}])
    assert Message.text(List.last(result.messages)) == "The fallback answered."

    assert [[_text, %ContentBlock.Image{}], _pdf] = tool_contents(received_messages())

    assert [[_text, %ContentBlock.Text{text: "[An image was left out" <> _rest}], _pdf] =
             tool_contents(received_messages())
  end

  defmodule Summary do
    use BeamWeaver.Schema

    field :topic, :string
  end

  test "the structured-response call after a tool loop gets the notice too" do
    lookup =
      BeamWeaver.Core.Tool.from_function!(
        name: "lookup",
        description: "Look something up.",
        input_schema: %{"type" => "object", "properties" => %{}},
        handler: fn _args, _opts -> "Nothing found." end
      )

    # The thread's assistant message is the fake model's first turn.
    responses = ["", "A chart and a report.", FakeChatModel.final(%{topic: "sales"})]

    assert {:ok, %{structured_response: %{"topic" => "sales"}}} =
             run(
               model: model(text_only(), responses: responses),
               tools: [lookup],
               response_format: BeamWeaver.Agent.StructuredOutput.tool(Summary)
             )

    # The tool loop's call, then the structured-response call.
    for _call <- 1..2 do
      assert [[_text, %ContentBlock.Text{text: "[An image was left out" <> _}], [_notice, %ContentBlock.Text{}]] =
               tool_contents(received_messages())
    end
  end

  test "a subagent's model gets the notice too" do
    looker = %{
      name: "looker",
      description: "Looks at photos.",
      model: model(text_only(), responses: ["A cat."]),
      middleware: [AttachPhoto]
    }

    task = FakeChatModel.tool_call("task", %{"subagent_type" => "looker", "description" => "What is in the photo?"})

    assert {:ok, _result} =
             run([model: %FakeChatModel{responses: [task, "It's a cat."]}, subagents: [looker]], ["Look at it"])

    assert [%Message{content: "What is in the photo?"}, %Message{content: [notice]}] =
             Enum.reject(received_messages(), &(&1.role == :system))

    assert notice == ContentBlock.text("[An image was left out: this model doesn't take images.]")
  end
end
