defmodule BeamWeaver.OpenAI.DecisionModelTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.{DecisionModel, Message}
  alias BeamWeaver.{Models, Serialization}
  alias BeamWeaver.OpenAI.Decisions.{ChoiceAnswer, PredicateAnswer, Question, RefusalAnswer, ScoreAnswer}
  alias BeamWeaver.Provider.Compatibility
  alias BeamWeaver.TestSupport.OpenAIDecisions, as: Fixture
  alias BeamWeaver.TestSupport.TypeSafe, as: TypeSafeFixture
  alias BeamWeaver.Transport.Response

  @image %{type: :image, base64: "AAAA", mime_type: "image/png"}
  @question %{"q" => Question.predicate(instructions: "Is it urgent?")}

  defp respond(body, status \\ 200),
    do: Fixture.model(respond: fn _ -> {:ok, Response.new(status: status, body: body)} end)

  test "gpt-6-luna is OpenAI's decision model as well as a chat model" do
    assert {:ok, model} =
             Models.init_decision_model("openai:gpt-6-luna",
               api_key: "key",
               organization: "org",
               project: "proj",
               timeout: 5_000
             )

    assert %BeamWeaver.OpenAI.DecisionModel{model: "gpt-6-luna", client: %{organization: "org", timeout: 5_000}} = model
    assert DecisionModel.model?(model)
    assert Compatibility.supports?(model, :decision_output)
    assert {:ok, %BeamWeaver.OpenAI.ChatModel{}} = Models.init_chat_model("openai:gpt-6-luna")

    assert {:error, %{type: :unsupported_model_param}} =
             Models.init_decision_model("openai:gpt-6-luna", temperature: 0.2)

    assert {:error, %{type: :unsupported_feature}} =
             DecisionModel.invoke(model, %{state: "x", questions: @question}, seed: 1)
  end

  test "one request asks every question and reads every kind of answer" do
    body = %{
      "model" => "gpt-6-luna",
      "answers" => [
        %{
          "type" => "choice",
          "name" => "department",
          "choice" => "technical",
          "confidence" => 0.97,
          "probabilities" => [
            %{"value" => "billing", "probability" => 0.01},
            %{"value" => "technical", "probability" => 0.99}
          ]
        },
        %{"type" => "predicate", "name" => "urgent", "probability" => 0.95},
        %{
          "type" => "score",
          "name" => "frustration",
          "score" => 0.94,
          "confidence" => 0.8,
          "probabilities" => [
            %{"value" => 0, "label" => "Calm", "probability" => 0.06},
            %{"value" => 1, "label" => "Angry", "probability" => 0.94}
          ]
        }
      ],
      "usage" => %{
        "input_tokens" => 1000,
        "input_tokens_details" => %{"cached_tokens" => 400, "cache_write_tokens" => 0},
        "output_tokens" => 2,
        "output_tokens_details" => %{"reasoning_tokens" => 0},
        "total_tokens" => 1002
      }
    }

    model =
      Fixture.model(
        respond: fn _ -> {:ok, Response.new(status: 200, body: body, headers: [{"x-request-id", "req_1"}])} end
      )

    model = %{
      model
      | profile: %{
          model.profile
          | extra: %{
              input_price_per_mtok: 2.0,
              cached_input_price_per_mtok: 0.5,
              output_price_per_mtok: 4.0
            }
        }
    }

    questions = %{
      "urgent" => Question.predicate(instructions: "Is this request urgent?"),
      department: Question.choice(instructions: "Which team?", choices: [{"billing", "Payments."}, {"technical", nil}]),
      frustration:
        Question.score(instructions: "How frustrated?", levels: ["Calm", %{label: "Angry", description: "Shouting."}])
    }

    assert {:ok, response} =
             DecisionModel.invoke(model, %{state: "Stripe has failed for three days.", questions: questions})

    assert_receive {:decisions_request, request}
    assert request.url == "https://api.openai.com/v1/decisions"
    assert {"authorization", "Bearer fixture-secret"} in request.headers
    assert request.json["model"] == "gpt-6-luna"
    assert request.json["input"] == "Stripe has failed for three days."

    assert Enum.sort_by(request.json["questions"], & &1["name"]) == [
             %{
               "type" => "choice",
               "name" => "department",
               "instructions" => "Which team?",
               "choices" => [%{"value" => "billing", "description" => "Payments."}, %{"value" => "technical"}]
             },
             %{
               "type" => "score",
               "name" => "frustration",
               "instructions" => "How frustrated?",
               "levels" => [%{"label" => "Calm"}, %{"label" => "Angry", "description" => "Shouting."}]
             },
             %{"type" => "predicate", "name" => "urgent", "instructions" => "Is this request urgent?"}
           ]

    assert %ChoiceAnswer{
             choice: "technical",
             confidence: 0.97,
             probabilities: %{"billing" => 0.01, "technical" => 0.99}
           } =
             response.answers["department"]

    assert %PredicateAnswer{probability: 0.95} = response.answers["urgent"]

    assert %ScoreAnswer{score: 0.94, legend: %{0 => "Calm", 1 => "Angry"}, probabilities: %{0 => 0.06, 1 => 0.94}} =
             response.answers["frustration"]

    assert %{model: "gpt-6-luna", requested_model: "gpt-6-luna", request_id: "req_1"} = response

    assert response.usage == %{
             input_tokens: 1000,
             output_tokens: 2,
             total_tokens: 1002,
             input_token_details: %{cache_read: 400, cache_write: 0},
             output_token_details: %{reasoning: 0}
           }

    # Decisions never bill output, even with a nonzero rate in the supplied profile.
    assert response.metadata.cost.output_cost == 0.0
    assert_in_delta response.metadata.cost.total_cost, 0.0014, 1.0e-12
  end

  test "boolean choices, refusals and answers of types added since" do
    body = %{
      "model" => "gpt-6-luna",
      "answers" => [
        %{
          "type" => "choice",
          "name" => "flag",
          "choice" => true,
          "confidence" => 0.98,
          "probabilities" => [%{"value" => false, "probability" => 0.01}, %{"value" => true, "probability" => 0.99}]
        },
        %{"type" => "refusal", "name" => "unsafe"},
        %{"type" => "ranking", "name" => "future", "order" => []}
      ],
      "usage" => %{"input_tokens" => 10, "output_tokens" => 0, "total_tokens" => 10}
    }

    questions = %{
      "flag" =>
        Question.choice(instructions: "Is a provider named?", choices: %{true => "A provider is named.", false => nil}),
      "unsafe" => Question.predicate(instructions: "Unsafe?"),
      "future" => Question.predicate(instructions: "Later?")
    }

    assert {:ok, response} = DecisionModel.invoke(respond(body), %{state: "Stripe is down.", questions: questions})
    assert_receive {:decisions_request, request}
    flag = Enum.find(request.json["questions"], &(&1["name"] == "flag"))
    assert flag["choices"] == [%{"value" => false}, %{"value" => true, "description" => "A provider is named."}]
    assert %ChoiceAnswer{choice: true, probabilities: %{true => 0.99, false => 0.01}} = response.answers["flag"]
    assert %RefusalAnswer{} = response.answers["unsafe"]
    refute Map.has_key?(response.answers, "future")
  end

  test "user messages go as they are, with their images" do
    hosted = %{type: :image, url: "https://example.test/cat.png"}
    state = [Message.user(["Look", @image]), Message.user([hosted])]
    assert {:ok, _response} = DecisionModel.invoke(Fixture.model(), %{state: state, questions: @question})
    assert_receive {:decisions_request, request}

    assert request.json["input"] == [
             %{
               "role" => "user",
               "content" => [
                 %{"type" => "input_text", "text" => "Look"},
                 %{"type" => "input_image", "image_url" => "data:image/png;base64,AAAA"}
               ]
             },
             %{
               "role" => "user",
               "content" => [%{"type" => "input_image", "image_url" => "https://example.test/cat.png"}]
             }
           ]
  end

  test "other state goes as JSON text, with the images of its messages where they appear" do
    call = %{id: "c1", name: "delete_file", args: %{path: "/tmp/x"}}
    state = %{messages: [Message.user(["Delete this", @image]), Message.assistant("", tool_calls: [call])], step: 2}
    assert {:ok, _response} = DecisionModel.invoke(Fixture.model(), %{state: state, questions: @question})
    assert_receive {:decisions_request, request}

    assert [
             %{
               "role" => "user",
               "content" => [
                 %{"type" => "input_text", "text" => before},
                 %{"type" => "input_image", "image_url" => "data:image/png;base64,AAAA"},
                 %{"type" => "input_text", "text" => rest}
               ]
             }
           ] = request.json["input"]

    assert BeamWeaver.JSON.decode!(before <> "IMAGE" <> rest) == %{
             "messages" => [
               %{
                 "role" => "user",
                 "content" => [%{"type" => "text", "text" => "Delete this"}, %{"type" => "text", "text" => "IMAGE"}]
               },
               %{
                 "role" => "assistant",
                 "content" => "",
                 "tool_calls" => [%{"id" => "c1", "name" => "delete_file", "args" => %{"path" => "/tmp/x"}}]
               }
             ],
             "step" => 2
           }
  end

  test "requests the API can't take fail before they are sent" do
    many_images = Message.user(List.duplicate(@image, 129))

    for {input, message} <- [
          {%{state: "x", questions: %{"c" => Question.choice(instructions: "x", choices: %{"only" => nil})}},
           "2 to 255 distinct choices"},
          {%{
             state: "x",
             questions: %{"c" => Question.choice(instructions: "x", choices: [{"a", nil}, {"a", "again"}])}
           }, "distinct choices"},
          {%{state: "x", questions: %{"s" => Question.score(instructions: "x", levels: ["only"])}},
           "two or more levels"},
          {%{state: "x", questions: %{"p" => Question.predicate(instructions: %{question: "x"})}}, "non-empty string"},
          {%{state: "x", questions: %{}}, "1 to 200 questions"},
          {%{state: "x", questions: Map.new(1..201, &{"q#{&1}", Question.predicate(instructions: "x")})}, "1 to 200"},
          {%{state: Message.user([%{type: :file, url: "https://example.test/a.pdf"}]), questions: @question},
           "text and images"},
          {%{state: Message.user([%{type: :image, file_id: "file_1"}]), questions: @question}, "not file IDs"},
          {%{state: %{messages: [Message.assistant([%{type: :reasoning, reasoning: "hmm"}])]}, questions: @question},
           "convert other content"},
          {%{state: %{at: DateTime.utc_now()}, questions: @question}, "struct"},
          {%{state: many_images, questions: @question}, "at most 128 images"}
        ] do
      assert {:error, %{type: :invalid_decision_input} = error} = DecisionModel.invoke(Fixture.model(), input)
      assert error.message =~ message
    end

    refute_received {:decisions_request, _request}
  end

  test "an API error keeps its status, and a malformed answer is an invalid response" do
    error = %{"error" => %{"message" => "Too many images.", "type" => "invalid_request_error"}}

    assert {:error, %{type: :invalid_request, details: %{status: 400}}} =
             DecisionModel.invoke(respond(error, 400), %{state: "x", questions: @question})

    malformed = %{"model" => "gpt-6-luna", "answers" => [%{"type" => "predicate", "name" => "q", "probability" => 2}]}

    assert {:error, %{type: :invalid_provider_response}} =
             DecisionModel.invoke(respond(malformed), %{state: "x", questions: @question})
  end

  test "choose and probability ask an OpenAI or a TypeSafe model alike, through a cache" do
    for model <- [Fixture.model(), TypeSafeFixture.model()] do
      cached = Models.cached(model, BeamWeaver.Cache.ETS.new(visibility: :private))

      assert {:ok, choice} =
               DecisionModel.choice_question(cached, "Which model?", %{"fast" => "Simple.", "powerful" => "Hard."})

      assert {:ok, %{choice: route, confidence: 0.9}, _response} = DecisionModel.choose(cached, "2 + 2?", choice)
      assert route in ["fast", "powerful"]
      assert {:ok, yes_no} = DecisionModel.yes_no_question(cached, "Is it urgent?")
      assert {:ok, probability, response} = DecisionModel.probability(cached, "Now!", yes_no)
      assert probability in [0.2, 0.98]
      assert {:ok, _probability, hit} = DecisionModel.probability(cached, "Now!", yes_no)
      assert hit.metadata.cache_hit
      assert hit.metadata.cost.total_cost == 0.0
      assert hit.metadata.original_usage == response.usage
    end

    assert {:refused, %{answers: %{"probability" => %RefusalAnswer{}}}} =
             DecisionModel.probability(
               Fixture.model(refuse: true),
               "Now!",
               elem(DecisionModel.yes_no_question(Fixture.model(), "Is it urgent?"), 1)
             )

    assert {:error, %{type: :invalid_decision_input}} =
             DecisionModel.choice_question(Fixture.model(), "Which?", %{"only" => nil})
  end

  test "responses round-trip through serialization" do
    questions = %{
      "c" => Question.choice(instructions: "x", choices: %{true => nil, false => nil}),
      "s" => Question.score(instructions: "x", levels: ["a", "b"])
    }

    assert {:ok, response} = DecisionModel.invoke(Fixture.model(choice: true), %{state: "x", questions: questions})
    assert {:ok, bytes} = Serialization.dump(response)
    assert {:ok, ^response} = Serialization.load(bytes)
    assert %ScoreAnswer{legend: %{0 => "a", 1 => "b"}} = response.answers["s"]
  end
end
