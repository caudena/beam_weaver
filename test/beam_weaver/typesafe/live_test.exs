Code.require_file("../../../examples/typesafe_routing_prompts.exs", __DIR__)

defmodule BeamWeaver.TypeSafe.LiveTest do
  use ExUnit.Case, async: false
  @moduletag :typesafe_live

  alias BeamWeaver.Core.{DecisionModel, Message}
  alias BeamWeaver.TypeSafe.{ChoiceAnswer, Client, NoulAnswer, Question, ScoreAnswer}

  setup do
    key = System.get_env("TYPESAFE_API_KEY") || System.get_env("TYPESAFE_API")
    assert is_binary(key) and key != "", "Export TYPESAFE_API_KEY or TYPESAFE_API for --only typesafe_live"
    %{model: BeamWeaver.Models.init_decision_model!("typesafe:jev-1.13.0", api_key: key, timeout: 20_000)}
  end

  test "live primitives, nullable fields, structured legends and provider metadata", %{model: model} do
    assert {:ok, result} =
             DecisionModel.invoke(model, %{
               state: %{ticket: "The export button has a spelling mistake; exports work."},
               questions: %{
                 kind: Question.choice(criteria: %{cosmetic: nil, functional: nil}),
                 urgent: Question.noul(instructions: "Does `ticket` describe an urgent service outage?", criteria: nil),
                 impact:
                   Question.score(
                     instructions: %{question: "Rate the functional impact in `ticket`."},
                     criteria: [%{description: "Cosmetic only"}, ["Degraded functionality"], "Blocked functionality"]
                   )
               }
             })

    assert %ChoiceAnswer{choice: choice} = result.answers["kind"]
    assert choice in ["cosmetic", "functional"]
    assert %NoulAnswer{noul: probability} = result.answers["urgent"]
    assert probability >= 0 and probability <= 1

    assert %ScoreAnswer{legend: %{"0" => %{"description" => "Cosmetic only"}, "1" => ["Degraded functionality"]}} =
             result.answers["impact"]

    assert result.model == "jev-1.13.0"
    assert is_binary(result.request_id)
    assert result.usage.input_tokens > 0
    IO.inspect(%{model: result.model, usage: result.usage, latency_ms: result.latency_ms}, label: "Live Jev contract")
  end

  test "live routing applies the decision and confidence gate to deterministic chat models", %{model: model} do
    fast = %BeamWeaver.Models.FakeChatModel{response: "fast"}
    powerful = %BeamWeaver.Models.FakeChatModel{response: "powerful"}

    router =
      BeamWeaver.Agent.Middleware.TypeSafeModelRouter.new(
        classifier: model,
        min_confidence: 0.8,
        choices: %{
          "fast" => %{model: fast, criteria: "Direct lookups and spelling fixes"},
          "powerful" => %{model: powerful, criteria: "Architecture and complex correctness reasoning"}
        }
      )

    {:ok, agent} = BeamWeaver.Agent.build(model: fast, middleware: [router])

    assert {:ok, state} =
             BeamWeaver.Agent.invoke(agent, %{
               messages: [
                 Message.user("Design a partition-tolerant multi-region ledger and explain consistency tradeoffs.")
               ]
             })

    route = state.model_route
    assert is_number(route["confidence"])
    assert route["accepted"] == route["confidence"] >= 0.8
    assert List.last(state.messages).content == if(route["accepted"], do: route["choice"], else: "fast")
    IO.inspect(Map.take(route, ["choice", "confidence", "accepted", "usage", "latency_ms"]), label: "Live Jev routing")
  end

  test "live model discovery", %{model: model} do
    assert {:ok, %{models: models}} = Client.list_models(model.client)
    assert Enum.any?(models, &String.starts_with?(&1["name"], "jev-"))
  end

  test "reports held-out routing outcomes without treating confidence as accuracy", %{model: model} do
    fast = %BeamWeaver.Models.FakeChatModel{response: "fast"}
    powerful = %BeamWeaver.Models.FakeChatModel{response: "powerful"}

    router =
      BeamWeaver.Agent.Middleware.TypeSafeModelRouter.new(
        classifier: model,
        min_confidence: 0.8,
        choices: BeamWeaver.Examples.TypeSafeRouting.Prompts.choices(fast, powerful)
      )

    cases =
      Path.expand("../../fixtures/typesafe/routing_cases.json", __DIR__) |> File.read!() |> BeamWeaver.JSON.decode!()

    rows =
      Enum.map(cases, fn item ->
        update =
          BeamWeaver.Agent.Middleware.TypeSafeModelRouter.before_agent(
            router,
            %{messages: [Message.user(item["text"])]},
            %{}
          )

        route = update.model_route

        Map.merge(
          Map.take(item, ["id", "expected"]),
          Map.take(
            route,
            ["choice", "confidence", "accepted", "reason", "latency_ms", "usage"]
          )
        )
      end)

    scored = Enum.reject(rows, &is_nil(&1["expected"]))
    failures = Enum.filter(rows, &(&1["reason"] == "classifier_error"))
    fallback_count = Enum.count(rows, &(not &1["accepted"]))
    chosen_errors = Enum.count(scored, &(&1["choice"] != &1["expected"]))

    effective_errors =
      Enum.count(scored, fn row ->
        if(row["accepted"], do: row["choice"], else: "fast") != row["expected"]
      end)

    IO.inspect(rows, label: "Frozen routing evaluation (assistant-authored labels)", limit: :infinity)

    IO.inspect(
      %{
        cases: length(rows),
        scored: length(scored),
        errors: chosen_errors,
        effective_errors: effective_errors,
        provider_failures: length(failures),
        fallback_count: fallback_count
      },
      label: "Routing evaluation summary"
    )

    assert failures == []
    assert Enum.all?(rows, &is_number(&1["confidence"]))
  end
end
