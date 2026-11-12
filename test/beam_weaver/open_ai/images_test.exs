defmodule BeamWeaver.OpenAI.ImagesTest do
  use ExUnit.Case, async: false

  alias BeamWeaver.OpenAI.Images
  alias BeamWeaver.Tracing.Store

  test "GPT-Image-2.6 sends complexity, output format, and edit references" do
    for model <- ["gpt-image-2.6-flare", "gpt-image-2.6-sunburst"] do
      response = %{"data" => [%{"b64_json" => "image-bytes"}]}
      prompt = "Animate the subject."
      json = %{"model" => model, "prompt" => prompt, "complexity" => "medium"}

      opts = [
        model: model,
        complexity: :medium,
        api_key: "test-key",
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport
      ]

      generation = Map.merge(json, %{"output_format" => "svg", "svg" => %{"model" => "gpt-6.1-terra"}})

      assert {:ok, ^response} =
               BeamWeaver.OpenAI.generate_image(
                 prompt,
                 opts ++
                   [
                     output_format: :svg,
                     svg: %{model: "gpt-6.1-terra"},
                     transport_opts: [
                       expect: %{method: :post, path: "/v1/images/generations", json: generation},
                       body: response
                     ]
                   ]
               )

      edit =
        Map.merge(json, %{
          "output_format" => "gif",
          "frame_count" => 4,
          "frame_duration_ms" => 250,
          "images" => [%{"file_id" => "file-source"}],
          "markup" => %{"file_id" => "file-markup"}
        })

      assert {:ok, ^response} =
               BeamWeaver.OpenAI.edit_image(
                 prompt,
                 [%{file_id: "file-source"}],
                 opts ++
                   [
                     output_format: :gif,
                     frame_count: 4,
                     frame_duration_ms: 250,
                     markup: %{file_id: "file-markup"},
                     transport_opts: [expect: %{method: :post, path: "/v1/images/edits", json: edit}, body: response]
                   ]
               )
    end
  end

  test "direct Images API generation exports its model and usage without image bytes" do
    response = %{
      "data" => [%{"b64_json" => "base64-image-bytes"}],
      "svg_usage" => %{"model" => "gpt-6.1-terra", "input_tokens" => 9, "output_tokens" => 4},
      "usage" => %{
        "input_tokens" => 13,
        "output_tokens" => 196,
        "input_tokens_details" => %{"text_tokens" => 13, "image_tokens" => 0},
        "output_tokens_details" => %{"image_tokens" => 196, "text_tokens" => 0}
      }
    }

    assert {:ok, ^response} =
             Images.generate("A blue square",
               model: "fixture-image",
               api_key: "test-key",
               quality: "low",
               moderation: "auto",
               safety_identifier: "opaque-user",
               response_format: "b64_json",
               transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
               transport_opts: [
                 parent: self(),
                 expect: %{
                   method: :post,
                   path: "/v1/images/generations",
                   json: %{
                     "model" => "fixture-image",
                     "prompt" => "A blue square",
                     "quality" => "low",
                     "moderation" => "auto",
                     "safety_identifier" => "opaque-user",
                     "response_format" => "b64_json"
                   }
                 },
                 body: response
               ]
             )

    assert_received {:fake_transport_request, request}
    assert {"authorization", "Bearer test-key"} in request.headers

    run =
      Store.list()
      |> Enum.find(&(&1.name == "openai:fixture-image:images"))

    assert run.status == :ok
    assert run.metadata.model_provider == "openai"
    assert run.metadata.model_name == "fixture-image"
    assert run.usage == response["usage"]
    assert run.metadata.svg_usage == response["svg_usage"]
    assert run.outputs == %{image_count: 1}
    refute inspect(run) =~ "base64-image-bytes"
  end
end
