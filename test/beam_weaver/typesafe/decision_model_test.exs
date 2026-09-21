defmodule BeamWeaver.TypeSafe.DecisionModelTest do
  use ExUnit.Case, async: true
  alias BeamWeaver.Core.{Async, ChatModel, DecisionModel, Message}
  alias BeamWeaver.{Models, Runnable, Serialization}
  alias BeamWeaver.Provider.{Compatibility, Registry}
  alias BeamWeaver.TestSupport.TypeSafe, as: Fixture
  alias BeamWeaver.TypeSafe.{ChoiceAnswer, Client, Input, NoulAnswer, Question, ScoreAnswer}
  alias BeamWeaver.Transport.Response

  test "initialization, discovery, aliases and explicit capabilities" do
    for id <- ["jev-1.13.0", "jev-latest", "jev-preview", "jev-future"] do
      assert {:ok, model} = Models.init_decision_model("typesafe:#{id}")
      assert model.model == id
      assert Compatibility.supports?(model, :decision_output)
      refute Compatibility.supports?(model, :text_output)
      refute Compatibility.supports?(model, :streaming)
      refute Compatibility.supports?(model, :tool_calling)
    end

    assert :typesafe in Registry.providers()
    assert Enum.any?(Compatibility.matrix(), &(&1.provider == :typesafe and &1.features.decision_output))
    assert {:error, %{type: :invalid_model}} = Models.init_decision_model("jev-latest")
    assert {:error, %{type: :unsupported_feature}} = Models.init_chat_model("typesafe:jev-latest")
    assert {:error, %{type: :unsupported_feature}} = Models.init_embeddings("typesafe:jev-latest")
    assert {:error, %{type: :unsupported_feature}} = ChatModel.invoke(Fixture.model(), [Message.user("hello")])
  end

  test "one native request preserves all answers, structured legend, usage, resolved model and ID" do
    assert {:ok, response} = DecisionModel.invoke(Fixture.model(), Fixture.input())
    assert response.model == "jev-1.13.0"
    assert response.request_id == "req-fixture"
    assert response.usage == %{input_tokens: 100, output_tokens: 20, total_tokens: 120}
    assert response.latency_ms >= 0
    assert_in_delta response.metadata.cost.total_cost, 0.0000042, 0.000000001
    assert %ChoiceAnswer{choice: "powerful", confidence: 0.9} = response.answers["route"]
    assert %NoulAnswer{noul: 0.98} = response.answers["urgency"]
    assert %ScoreAnswer{legend: %{"0" => %{"level" => "cosmetic"}, "1" => ["degraded"]}} = response.answers["severity"]
    assert_receive {:typesafe_request, request}
    assert request.url == "https://api.typesafe.ai/v1/systemone"
    assert request.method == :post
    assert {"authorization", "Bearer fixture-secret"} in request.headers
    assert request.json["questions"]["severity"]["instructions"] == nil
    refute_received {:typesafe_request, _}
  end

  test "future resolved versions do not inherit known-model pricing" do
    {:ok, input} = Input.normalize(Fixture.input())
    body = Fixture.body(input["questions"]) |> Map.put("model", "jev-future")
    assert {:ok, %{metadata: %{cost: nil}}} = DecisionModel.invoke(Fixture.model(body: body), Fixture.input())
  end

  test "nested messages preserve role, text and tool calls without exporting metadata" do
    msg =
      Message.assistant("",
        tool_calls: [%{id: "c", name: "lookup", args: %{query: "hello"}}],
        metadata: %{secret: "hidden"}
      )

    input = %{
      state: %{conversation: [Message.user("hi"), msg, Message.tool("found", tool_call_id: "c")]},
      questions: %{ok: Question.noul(instructions: "Was a tool used?")}
    }

    assert {:ok, _} = DecisionModel.invoke(Fixture.model(), input)
    assert_receive {:typesafe_request, request}
    assert [user, assistant, tool] = request.json["state"]["conversation"]
    assert user["role"] == "user"
    assert [%{"id" => "c", "name" => "lookup"}] = assistant["tool_calls"]
    assert tool["tool_call_id"] == "c"
    refute Map.has_key?(assistant, "metadata")
  end

  test "API permits omitted instructions, nullable Noul criteria and Choice descriptions" do
    input = %{
      state: "A ticket",
      questions: %{
        c: %{type: :choice, criteria: %{a: nil, b: "B"}},
        n: %{type: :noul, instructions: nil, criteria: nil}
      }
    }

    assert {:ok, _} = DecisionModel.invoke(Fixture.model(), input)
  end

  test "invalid inputs fail locally instead of dropping evidence" do
    valid = Fixture.input()

    inputs = [
      %{valid | state: nil},
      %{valid | questions: %{}},
      %{valid | state: %{1 => "bad key"}},
      %{valid | state: %{"x" => 2, x: 1}},
      %{valid | state: <<255>>},
      %{valid | state: fn -> :bad end},
      %{valid | state: Message.user([%{type: :image, url: "https://example.test/img"}])},
      %{state: "x", questions: %{q: Question.score(criteria: ["one", nil])}},
      %{state: "x", questions: %{q: Question.score(criteria: ["one"])}},
      %{state: "x", questions: %{q: %{type: "unknown"}}},
      %{state: "x", questions: %{q: Question.choice(criteria: Map.new(1..256, &{to_string(&1), nil}))}}
    ]

    for input <- inputs, do: assert({:error, _} = DecisionModel.invoke(Fixture.model(), input))
    assert {:error, _} = DecisionModel.invoke(Fixture.model(), valid, max_bytes: 1)
    assert {:error, %{type: :unsupported_feature}} = DecisionModel.invoke(Fixture.model(), valid, stream: true)
    refute_received {:typesafe_request, _}
  end

  test "malformed typed responses cannot become successful decisions" do
    {:ok, input} = Input.normalize(Fixture.input())
    valid = Fixture.body(input["questions"])

    bodies = [
      Map.delete(valid, "usage"),
      put_in(valid, ["usage", "input_tokens"], -1),
      put_in(valid, ["answers", "urgency", "noul"], 2),
      update_in(valid, ["answers"], &Map.delete(&1, "route")),
      put_in(valid, ["answers", "route", "choice"], "unknown"),
      put_in(valid, ["answers", "route", "confidence"], nil),
      put_in(valid, ["answers", "route", "probabilities"], %{"fast" => 0.5}),
      put_in(valid, ["answers", "severity", "legend"], %{}),
      put_in(valid, ["answers", "severity", "score"], 12),
      "not json",
      []
    ]

    for body <- bodies do
      assert {:error, _} = DecisionModel.invoke(Fixture.model(body: body), Fixture.input())
    end
  end

  for status <- [401, 422, 429, 529, 503] do
    @status status
    test "HTTP #{status} errors preserve status, request ID and retryability without implicit retry" do
      model =
        Fixture.model(
          respond: fn _ ->
            {:ok,
             Response.new(
               status: @status,
               headers: [{"x-typesafe-request-id", "failed"}],
               body: %{"detail" => "fixture error"}
             )}
          end
        )

      assert {:error, error} = DecisionModel.invoke(model, Fixture.input())
      assert error.details.status == @status
      assert error.details.request_id == "failed"
      assert BeamWeaver.RetryPredicates.transient?(error) == @status in [429, 529, 503]
      assert_receive {:typesafe_request, _}
      refute_received {:typesafe_request, _}
    end
  end

  test "transport failures and missing credentials are explicit errors" do
    model = Fixture.model(respond: fn _ -> {:error, BeamWeaver.Transport.Error.new(:timeout, "timed out")} end)
    assert {:error, %{type: :transport_error}} = DecisionModel.invoke(model, Fixture.input())
    client = Client.new(api_key: nil, transport: Fixture.Transport)
    model = %{Fixture.model() | client: client}
    assert {:error, %{type: :model_authentication}} = DecisionModel.invoke(model, Fixture.input())
  end

  test "models endpoint uses the shared client and preserves request metadata" do
    client =
      Client.new(
        api_key: "fixture",
        base_url: "https://gateway.test/",
        transport: Fixture.Transport,
        transport_opts: [
          parent: self(),
          body: %{"models" => [%{"name" => "jev-latest", "description" => "stable", "release_date" => "2026-09-15"}]}
        ]
      )

    assert {:ok, %{models: [%{"name" => "jev-latest"}], request_id: "req-fixture"}} = Client.list_models(client)
    assert_receive {:typesafe_request, %{method: :get, url: "https://gateway.test/v1/models"}}
  end

  test "Runnable composition, bounded batch, async and one-result streams" do
    model = Fixture.model()
    pipeline = Runnable.sequence([model, Runnable.lambda(& &1.answers["urgency"].noul)])
    assert {:ok, 0.98} = Runnable.invoke(pipeline, Fixture.input())
    assert {:ok, [_, _]} = DecisionModel.batch(model, [Fixture.input(), Fixture.input()], max_concurrency: 2)
    assert {:ok, _} = model |> DecisionModel.async_invoke(Fixture.input()) |> Async.await()
    assert {:ok, stream} = Runnable.stream(model, Fixture.input())
    assert [%BeamWeaver.TypeSafe.Response{}] = Enum.to_list(stream)
  end

  test "response serialization preserves typed answers and structured criteria" do
    assert {:ok, response} = DecisionModel.invoke(Fixture.model(), Fixture.input())
    assert {:ok, bytes} = Serialization.dump(response)
    assert {:ok, restored} = Serialization.load(bytes)
    assert restored.answers == response.answers
    assert restored.model == response.model
    assert restored.usage.total_tokens == 120
    assert restored.metadata.cost == response.metadata.cost
    cached = BeamWeaver.TypeSafe.Response.cached(restored)
    assert {:ok, _} = Serialization.dump(cached)
    assert cached.metadata.original_usage.total_tokens == 120
    assert {:error, _} = Serialization.dump(Fixture.model())
  end

  test "a graph node can classify and checkpoint its typed result" do
    model = Fixture.model()

    graph =
      BeamWeaver.Graph.new()
      |> BeamWeaver.Graph.add_node(:classify, fn state ->
        with {:ok, response} <- DecisionModel.invoke(model, state.input), do: %{decision: response}
      end)
      |> BeamWeaver.Graph.add_edge(BeamWeaver.Graph.start(), :classify)
      |> BeamWeaver.Graph.add_edge(:classify, BeamWeaver.Graph.end_node())
      |> BeamWeaver.Graph.compile!()

    assert {:ok, result} = BeamWeaver.Graph.Compiled.invoke(graph, %{input: Fixture.input()})
    assert %NoulAnswer{} = result.decision.answers["urgency"]
    assert {:ok, encoded} = Serialization.dump(result.decision)
    assert {:ok, restored} = Serialization.load(encoded)
    assert restored.usage.total_tokens == 120
  end

  test "cached decisions reuse results without additional billed usage" do
    cache = BeamWeaver.Cache.ETS.new(visibility: :private)
    model = Models.cached(Fixture.model(), cache)
    assert {:ok, first} = DecisionModel.invoke(model, Fixture.input())
    assert {:ok, second} = DecisionModel.invoke(model, Fixture.input())
    assert first.answers == second.answers
    assert second.usage.total_tokens == 0
    assert second.metadata.cache_hit
    assert second.metadata.cost.total_cost == 0
    assert_receive {:typesafe_request, _}
    refute_received {:typesafe_request, _}
  end

  test "client and model inspection cannot expose credentials" do
    model = Fixture.model()
    refute inspect(model, limit: :infinity) =~ "fixture-secret"
    refute inspect(model.client, limit: :infinity) =~ "fixture-secret"
  end
end
