defmodule BeamWeaver.Provider.ToolResultMediaTest do
  # How each provider sends a tool result that holds an image or a PDF, as
  # `read_file` returns them: inside the tool result where the API takes media
  # there, otherwise in a user message right after the run of tool results.
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Models

  @png Base.encode64(<<137, 80, 78, 71, 13, 10, 26, 10>>)
  @pdf Base.encode64("%PDF-1.4\n%%EOF")
  @image_url "data:image/png;base64," <> @png
  @pdf_url "data:application/pdf;base64," <> @pdf

  defp image_result,
    do:
      Message.tool([ContentBlock.text("File /chart.png is an image (8 bytes)."), image()],
        tool_call_id: "call_1",
        name: "read_file"
      )

  defp pdf_result,
    do:
      Message.tool([ContentBlock.text("File /report.pdf is a PDF (15 bytes)."), pdf()],
        tool_call_id: "call_2",
        name: "read_file"
      )

  defp image, do: ContentBlock.image(data: @png, mime_type: "image/png")
  defp pdf, do: ContentBlock.file(data: @pdf, mime_type: "application/pdf", filename: "report.pdf")

  defp thread(results, follow_up \\ [Message.user("What do they show?")]) do
    calls =
      for %Message{tool_call_id: id} <- results,
          do: %{id: id, name: "read_file", args: %{"file_path" => "/file"}}

    [Message.user("Look at the chart and the report"), Message.assistant("", tool_calls: calls)] ++
      results ++ follow_up
  end

  defp body!(spec, messages, opts \\ []) do
    model = Models.init_chat_model!(spec, Keyword.put(opts, :api_key, "test-key"))
    {:ok, body} = model.__struct__.request_body(model, messages, [])
    body
  end

  defp roles(wire_messages), do: Enum.map(wire_messages, & &1["role"])

  describe "Chat Completions APIs, whose tool messages take text only" do
    for spec <- ["openai:gpt-5.4-mini", "xai:grok-4.7"] do
      test "#{spec} sends the media in a user message after the tool results" do
        %{"messages" => messages} =
          body!(unquote(spec), thread([image_result(), pdf_result()]), api: :chat_completions)

        assert roles(messages) == ["user", "assistant", "tool", "tool", "user", "user"]

        assert [
                 %{"content" => "File /chart.png is an image (8 bytes).", "tool_call_id" => "call_1"},
                 %{"content" => "File /report.pdf is a PDF (15 bytes).", "tool_call_id" => "call_2"}
               ] = Enum.filter(messages, &(&1["role"] == "tool"))

        assert Enum.at(messages, 4)["content"] == [
                 %{"type" => "text", "text" => "Attached to the read_file result for call_1:"},
                 %{"type" => "image_url", "image_url" => %{"url" => @image_url}},
                 %{"type" => "text", "text" => "Attached to the read_file result for call_2:"},
                 %{"type" => "file", "file" => %{"file_data" => @pdf_url, "filename" => "report.pdf"}}
               ]

        assert List.last(messages)["content"] == "What do they show?"
      end
    end

    test "Moonshot sends text in the tool message and the image after it" do
      %{"messages" => messages} = body!("moonshot:kimi-k3", thread([image_result()], []))

      assert roles(messages) == ["user", "assistant", "tool", "user"]
      assert Enum.at(messages, 2)["content"] == "File /chart.png is an image (8 bytes)."

      assert List.last(messages)["content"] == [
               %{"type" => "text", "text" => "Attached to the read_file result for call_1:"},
               %{"type" => "image_url", "image_url" => %{"url" => @image_url}}
             ]
    end

    test "Moonshot rejects a PDF from a tool, as it does in a user message" do
      model = Models.init_chat_model!("moonshot:kimi-k3", api_key: "test-key")

      assert {:error, %BeamWeaver.Core.Error{type: :unsupported_feature, details: %{feature: :file_input}}} =
               model.__struct__.request_body(model, thread([pdf_result()]), [])
    end

    test "Z.ai sends the media of a model that reads it after the tool messages" do
      %{"messages" => messages} = body!("zai:glm-5.3-flash", thread([image_result(), pdf_result()], []))

      assert roles(messages) == ["user", "assistant", "tool", "tool", "user"]
      assert Enum.at(messages, 3)["content"] == "File /report.pdf is a PDF (15 bytes)."

      assert List.last(messages)["content"] == [
               %{"type" => "text", "text" => "Attached to the read_file result for call_1:"},
               %{"type" => "image_url", "image_url" => %{"url" => @image_url}},
               %{"type" => "text", "text" => "Attached to the read_file result for call_2:"},
               %{"type" => "file", "file" => %{"file_data" => @pdf_url, "filename" => "report.pdf"}}
             ]
    end

    test "Z.ai rejects tool media for a text-only model before the request" do
      model = Models.init_chat_model!("zai:glm-5.3", api_key: "test-key")

      assert {:error, %BeamWeaver.Core.Error{type: :unsupported_feature, details: %{feature: :image}}} =
               model.__struct__.request_body(model, thread([image_result()]), [])
    end

    test "a tool result that is only media keeps a line in the tool message" do
      only_image = Message.tool([image()], tool_call_id: "call_1", name: "read_file")
      %{"messages" => messages} = body!("openai:gpt-5.4-mini", thread([only_image], []), api: :chat_completions)

      assert Enum.at(messages, 2)["content"] == "The result is attached in the next message."
      assert [%{"type" => "text"}, %{"type" => "image_url"}] = List.last(messages)["content"]
    end
  end

  test "DeepSeek Flash takes images inside the tool message" do
    %{"messages" => messages} = body!("deepseek:deepseek-flash", thread([image_result()], []))

    assert roles(messages) == ["user", "assistant", "tool"]

    assert List.last(messages)["content"] == [
             %{"type" => "text", "text" => "File /chart.png is an image (8 bytes)."},
             %{"type" => "image_url", "image_url" => %{"url" => @image_url}}
           ]
  end

  test "Anthropic puts images and PDFs in the tool_result with their media types" do
    %{"messages" => [_user, _assistant, %{"role" => "user", "content" => blocks}]} =
      body!("anthropic:claude-haiku-4-5", thread([image_result(), pdf_result()], []))

    assert [
             %{"type" => "tool_result", "content" => image_content},
             %{"type" => "tool_result", "content" => pdf_content}
           ] =
             blocks

    assert [
             %{"type" => "text", "text" => "File /chart.png is an image (8 bytes)."},
             %{"type" => "image", "source" => %{"type" => "base64", "media_type" => "image/png", "data" => @png}}
           ] = image_content

    assert [
             %{"type" => "text"},
             %{
               "type" => "document",
               "source" => %{"type" => "base64", "media_type" => "application/pdf", "data" => @pdf}
             }
           ] = pdf_content
  end

  test "Gemini puts images and PDFs in the function response parts" do
    %{"contents" => [_user, _model, %{"role" => "user", "parts" => parts}]} =
      body!("google:gemini-3.8-flash", thread([image_result(), pdf_result()], []))

    assert [%{"functionResponse" => image_response}, %{"functionResponse" => pdf_response}] = parts

    assert image_response["response"] == %{"content" => "File /chart.png is an image (8 bytes)."}
    assert image_response["parts"] == [%{"inlineData" => %{"mimeType" => "image/png", "data" => @png}}]

    assert pdf_response["response"] == %{"content" => "File /report.pdf is a PDF (15 bytes)."}
    assert pdf_response["parts"] == [%{"inlineData" => %{"mimeType" => "application/pdf", "data" => @pdf}}]
  end

  for spec <- ["openai:gpt-5.4-mini", "xai:grok-4.7"] do
    test "#{spec} Responses puts images and PDFs in the function_call_output" do
      %{"input" => input} = body!(unquote(spec), thread([image_result(), pdf_result()], []))

      assert [image_output, pdf_output] = Enum.filter(input, &(&1["type"] == "function_call_output"))

      assert image_output["output"] == [
               %{"type" => "input_text", "text" => "File /chart.png is an image (8 bytes)."},
               %{"type" => "input_image", "image_url" => @image_url}
             ]

      assert [
               %{"type" => "input_text"},
               %{"type" => "input_file", "file_data" => @pdf_url, "filename" => "report.pdf"}
             ] = pdf_output["output"]
    end
  end
end
