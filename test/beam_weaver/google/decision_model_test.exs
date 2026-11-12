defmodule BeamWeaver.Google.DecisionModelTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.{ContentBlock, DecisionModel, Message}
  alias BeamWeaver.Google.Decisions.{ChoiceAnswer, Input, NoulAnswer, Question, ScoreAnswer}
  alias BeamWeaver.{Cache, Models, Serialization}

  test "the registered Gemini model sends multimodal input and decodes the three answer types" do
    questions = %{
      valid: Question.noul(instructions: "Is the image relevant?"),
      route: Question.choice(instructions: "Which queue?", criteria: %{general: "", support: "Product issues"}),
      urgency: Question.score(instructions: "How urgent?", criteria: ["Can wait", "Urgent"])
    }

    body = %{
      "answers" => %{
        "valid" => %{"type" => "noul", "noul" => 0.9, "confidence" => 0.9},
        "route" => %{
          "type" => "choice",
          "choice" => "support",
          "confidence" => 0.8,
          "probabilities" => %{"general" => 0.2, "support" => 0.8}
        },
        "urgency" => %{
          "type" => "score",
          "score" => 0.6,
          "confidence" => 0.6,
          "probabilities" => %{"0" => 0.4, "1" => 0.6},
          "legend" => %{"0" => "Can wait", "1" => "Urgent"}
        }
      },
      "usage" => %{"total_input_tokens" => 100, "total_output_tokens" => 0, "total_tokens" => 100}
    }

    model =
      Models.init_decision_model!("google:gemini-decision-1",
        api_key: "fixture-key",
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [parent: self(), body: body]
      )

    state = ["Check this image", ContentBlock.image(url: "https://example.test/item.png", mime_type: "image/png")]
    input = %{state: state, questions: questions}
    cached = Models.cached(model, Cache.ETS.new(visibility: :private))

    assert {:ok, result} = DecisionModel.invoke(cached, input, trace?: false)
    assert_received {:fake_transport_request, request}
    assert request.url == "https://generativelanguage.googleapis.com/v1beta/decisions"
    assert {"x-goog-api-key", "fixture-key"} in request.headers
    assert request.json["model"] == "gemini-decision-1"

    assert request.json["input"] == [
             %{"type" => "text", "text" => "Check this image"},
             %{"type" => "image", "mime_type" => "image/png", "uri" => "https://example.test/item.png"}
           ]

    assert get_in(request.json, ["questions", "route", "criteria", "support"]) == "Product issues"
    assert %NoulAnswer{noul: 0.9} = result.answers["valid"]
    assert %ChoiceAnswer{choice: "support"} = result.answers["route"]
    assert %ScoreAnswer{legend: %{0 => "Can wait", 1 => "Urgent"}} = result.answers["urgency"]
    assert result.usage.output_tokens == 0
    assert_in_delta result.metadata.cost.total_cost, 0.00001, 1.0e-12
    assert {:ok, saved} = Serialization.dump(result)
    assert {:ok, ^result} = Serialization.load(saved)

    assert {:ok, hit} = DecisionModel.invoke(cached, input, trace?: false)
    assert hit.answers == result.answers
    assert hit.metadata.original_usage == result.usage
    assert hit.metadata.cost.total_cost == 0.0
    refute_received {:fake_transport_request, _request}

    assert {:error, %{type: :unsupported_model}} = Models.init_chat_model("google:gemini-decision-1")
    assert {:error, %{type: :unsupported_model}} = Models.init_decision_model("google:gemini-4-carbon")
  end

  test "structured decision state projects message history and sends embedded media as provider parts" do
    uri = "https://example.test/item.png"
    image = ContentBlock.image(url: uri, mime_type: "image/png")

    state = %{
      message: Message.user(["Inspect this.", image], id: "local-message-id", metadata: %{private: "internal"}),
      route: "support"
    }

    question = Question.noul(instructions: "Is the item damaged?")

    assert {:ok, %{"input" => [before, media, after_media]}} =
             Input.request(%{state: state, questions: %{damage: question}})

    assert media == %{"type" => "image", "mime_type" => "image/png", "uri" => uri}

    assert BeamWeaver.JSON.decode!(before["text"] <> "IMAGE" <> after_media["text"]) == %{
             "message" => %{
               "content" => [%{"type" => "text", "text" => "Inspect this."}, %{"type" => "text", "text" => "IMAGE"}],
               "role" => "user"
             },
             "route" => "support"
           }
  end

  test "invalid question names and empty input fail before transport" do
    model = Models.init_decision_model!("google:gemini-decision-1")
    question = Question.noul(instructions: "Is this valid?")

    assert {:error, %{type: :invalid_decision_input}} =
             DecisionModel.invoke(model, %{state: "x", questions: %{"bad id" => question}})

    assert {:error, %{type: :invalid_decision_input}} =
             DecisionModel.invoke(model, %{state: "", questions: %{"q" => question}})
  end
end
