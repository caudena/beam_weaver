defmodule BeamWeaver.Core.ContentBlockTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.Serialization

  test "parses base64 data URIs into typed image, audio, video, and file blocks" do
    image_data = Base.encode64("png bytes")
    audio_data = Base.encode64("audio bytes")
    video_data = Base.encode64("video bytes")
    file_data = Base.encode64("pdf bytes")

    assert {:ok,
            %ContentBlock.Image{
              data: ^image_data,
              mime_type: "image/png",
              metadata: %{source: :data_uri, encoding: :base64}
            }} = ContentBlock.from("data:image/png;base64,#{image_data}")

    assert {:ok, %ContentBlock.Audio{data: ^audio_data, mime_type: "audio/mpeg"}} =
             ContentBlock.from("data:audio/mpeg;base64,#{audio_data}")

    assert {:ok, %ContentBlock.Video{data: ^video_data, mime_type: "video/mp4"}} =
             ContentBlock.from("data:video/mp4;base64,#{video_data}")

    assert {:ok, %ContentBlock.File{data: ^file_data, mime_type: "application/pdf"}} =
             ContentBlock.from("data:application/pdf;base64,#{file_data}")
  end

  test "parses percent-encoded text data URIs as text blocks" do
    assert {:ok,
            %ContentBlock.Text{
              text: "hello world",
              metadata: %{source: :data_uri, encoding: :url_encoded}
            }} = ContentBlock.from("data:text/plain,hello%20world")
  end

  test "rejects invalid data URIs with tagged errors" do
    assert {:error, %Error{type: :invalid_content_block}} =
             ContentBlock.from("data:image/png;base64,not base64 %%%")

    assert {:error, %Error{type: :invalid_content_block}} = ContentBlock.parse_data_uri("hello")
  end

  test "map conversion handles data URI URLs and unknown provider blocks without atom creation" do
    payload = Base.encode64("png bytes")

    assert {:ok, %ContentBlock.Image{data: ^payload, mime_type: "image/png", metadata: %{alt: "cat"}}} =
             ContentBlock.from(%{
               "type" => "image",
               "url" => "data:image/png;base64,#{payload}",
               "metadata" => %{alt: "cat"}
             })

    assert {:ok, %ContentBlock.Unknown{provider_type: "vendor.private", value: value}} =
             ContentBlock.from(%{
               "type" => "vendor.private",
               "payload" => %{"deep" => true}
             })

    assert value["payload"]["deep"]

    assert {:ok, %ContentBlock.Unknown{provider_type: "unknown", value: no_type}} =
             ContentBlock.from(%{"cachePoint" => %{"type" => "default"}})

    assert no_type["cachePoint"] == %{"type" => "default"}
  end

  test "a file part with a nested file map becomes a file block with its URL, id or data" do
    assert {:ok, %ContentBlock.File{url: "https://example.test/label.pdf", data: nil}} =
             ContentBlock.from(%{"type" => "file", "file" => %{"file_url" => "https://example.test/label.pdf"}})

    assert {:ok, %ContentBlock.File{url: "https://example.test/old.pdf"}} =
             ContentBlock.from(%{"type" => "file_url", "file_url" => %{"url" => "https://example.test/old.pdf"}})

    assert {:ok, %ContentBlock.File{file_id: "file-abc", url: nil}} =
             ContentBlock.from(%{"type" => "file", "file" => %{"file_id" => "file-abc"}})

    # A data URL in `file_data` gives the block its base64 payload and media type.
    assert {:ok, %ContentBlock.File{data: "JVBERi0=", mime_type: "application/pdf", filename: "label.pdf"}} =
             ContentBlock.from(%{
               "type" => "file",
               "file" => %{"file_data" => "data:application/pdf;base64,JVBERi0=", "filename" => "label.pdf"}
             })

    assert {:ok, %ContentBlock.File{data: "aGVsbG8gd29ybGQ=", mime_type: "text/plain"}} =
             ContentBlock.from(%{"type" => "file", "file" => %{"file_data" => "data:text/plain,hello%20world"}})

    assert {:error, %Error{type: :invalid_content_block}} =
             ContentBlock.from(%{"type" => "file", "file" => %{"file_data" => "data:application/pdf;base64,%%%"}})

    # So does a data URL where a URL goes.
    for part <- [
          %{"type" => "file", "file" => %{"file_url" => "data:application/pdf;base64,JVBERi0=", "filename" => "a.pdf"}},
          %{"type" => "file", "file" => %{"url" => "data:application/pdf;base64,JVBERi0="}},
          %{"type" => "file_url", "file_url" => %{"url" => "data:application/pdf;base64,JVBERi0="}},
          %{"type" => "file_url", "file_url" => "data:application/pdf;base64,JVBERi0="}
        ] do
      assert {:ok, %ContentBlock.File{url: nil, data: "JVBERi0=", mime_type: "application/pdf"}} =
               ContentBlock.from(part)
    end

    assert {:ok, %ContentBlock.File{url: nil, data: "aGVsbG8gd29ybGQ=", mime_type: "text/plain"}} =
             ContentBlock.from(%{"type" => "file_url", "file_url" => %{"url" => "data:text/plain,hello%20world"}})

    assert {:error, %Error{type: :invalid_content_block}} =
             ContentBlock.from(%{"type" => "file_url", "file_url" => "data:application/pdf;base64,%%%"})

    assert [%ContentBlock.Text{}, %ContentBlock.File{url: "https://example.test/label.pdf"}] =
             Message.user([
               "Summarize the label.",
               %{"type" => "file", "file" => %{"file_url" => "https://example.test/label.pdf"}}
             ]).content
  end

  test "content block helpers expose native known types and data classification" do
    assert :text in ContentBlock.known_types()
    assert :server_tool_call in ContentBlock.known_types()

    refute ContentBlock.data?(ContentBlock.text("plain"))
    assert ContentBlock.data?(ContentBlock.image(%{url: "https://example.test/image.png"}))
    assert ContentBlock.data?(%{"type" => "image_url", "image_url" => %{"url" => "https://x"}})
    assert ContentBlock.data?(%{"type" => "file", "data" => "abc"})
    assert ContentBlock.data?("data:text/plain,hello")
  end

  test "normalizes content block lists and preserves typed blocks through message serialization" do
    payload = Base.encode64("png bytes")

    assert {:ok, [%ContentBlock.Text{}, %ContentBlock.Image{} = image]} =
             ContentBlock.normalize_many([
               "caption",
               %{"type" => "image", "url" => "data:image/png;base64,#{payload}"}
             ])

    message = Message.user([image], id: "msg-content")
    encoded = Serialization.encode(message)

    assert [
             %{
               "type" => :image,
               "data" => ^payload,
               "mime_type" => "image/png",
               "metadata" => %{"source" => :data_uri, "encoding" => :base64}
             }
           ] = encoded["content"]

    assert {:ok, decoded} = Serialization.decode(encoded)
    assert decoded.id == "msg-content"
    assert [%ContentBlock.Image{data: ^payload, mime_type: "image/png"}] = decoded.content
  end
end
