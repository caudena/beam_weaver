defmodule BeamWeaver.OpenAI.ImagesTest do
  use ExUnit.Case, async: false

  alias BeamWeaver.OpenAI.Images
  alias BeamWeaver.Tracing.Store

  test "direct Images API generation exports its model and usage without image bytes" do
    response = %{
      "data" => [%{"b64_json" => "base64-image-bytes"}],
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
    assert run.outputs == %{image_count: 1}
    refute inspect(run) =~ "base64-image-bytes"
  end
end
