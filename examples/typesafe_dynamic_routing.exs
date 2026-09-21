# Live (default): mix run examples/typesafe_dynamic_routing.exs
# Offline fixtures: mix run examples/typesafe_dynamic_routing.exs --offline
# Export TYPESAFE_API_KEY (or TYPESAFE_API) and OPENAI_API_KEY before live runs.

Code.require_file("typesafe_routing_prompts.exs", __DIR__)

defmodule BeamWeaver.Examples.TypeSafeRouting do
  alias BeamWeaver.Agent, as: BWAgent
  alias BeamWeaver.Agent.Middleware.TypeSafeModelRouter
  alias BeamWeaver.Core.{DecisionModel, Message, Tool}
  alias BeamWeaver.{Config, Models}
  alias BeamWeaver.TypeSafe.Question

  @simple "Use multiply to calculate 7 times 8 and report the result in one sentence."
  @complex "Design a multi-region payment ledger that maintains correctness during network partitions. Explain the consistency model, duplicate event handling, and recovery tradeoffs. Keep the answer under 200 words."

  # Replays explicit fixtures only. This is not a heuristic substitute for Jev.
  defmodule FixtureTransport do
    @behaviour BeamWeaver.Transport
    def request(request, _opts) do
      questions = request.json["questions"]

      answers =
        if Map.has_key?(questions, "route") do
          text = request.json["state"]["message"]["content"]

          choice =
            case text do
              "Use multiply to calculate 7 times 8 and report the result in one sentence." ->
                "fast"

              "Design a multi-region payment ledger that maintains correctness during network partitions. Explain the consistency model, duplicate event handling, and recovery tradeoffs. Keep the answer under 200 words." ->
                "powerful"
            end

          %{
            "route" => %{
              "type" => "choice",
              "choice" => choice,
              "confidence" => 0.95,
              "probabilities" => %{
                "fast" => if(choice == "fast", do: 1.0, else: 0.0),
                "powerful" => if(choice == "powerful", do: 1.0, else: 0.0)
              }
            }
          }
        else
          %{
            "urgent" => %{"type" => "noul", "noul" => 0.99},
            "team" => %{
              "type" => "choice",
              "choice" => "engineering",
              "confidence" => 0.95,
              "probabilities" => %{"engineering" => 1.0, "billing" => 0.0}
            },
            "severity" => %{
              "type" => "score",
              "score" => 2.0,
              "confidence" => 0.98,
              "probabilities" => %{"0" => 0.0, "1" => 0.0, "2" => 1.0},
              "legend" => %{"0" => "Cosmetic only", "1" => "Degraded with workaround", "2" => "Customers blocked"}
            }
          }
        end

      {:ok,
       BeamWeaver.Transport.Response.new(
         status: 200,
         headers: [{"x-typesafe-request-id", "offline-fixture"}],
         body: %{
           "model" => "jev-1.13.0",
           "answers" => answers,
           "usage" => %{"input_tokens" => 200, "output_tokens" => 50}
         }
       )}
    end
  end

  defmodule FixtureChat do
    @behaviour BeamWeaver.Core.ChatModel
    defstruct [:model]

    def invoke(model, messages, _opts) do
      message =
        case model.model do
          "gpt-5.6-luna" ->
            if Enum.any?(messages, &(&1.role == :tool)),
              do: Message.assistant("7 times 8 is 56."),
              else:
                Message.assistant("", tool_calls: [%{id: "multiply-1", name: "multiply", args: %{"a" => 7, "b" => 8}}])

          "gpt-5.6-sol" ->
            Message.assistant(
              "Fixture: use a consensus-backed ledger, idempotency keys, and explicit partition recovery."
            )
        end

      {:ok, message}
    end
  end

  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [offline: :boolean])
    if rest != [] or invalid != [], do: raise(ArgumentError, "usage: typesafe_dynamic_routing.exs [--offline]")
    offline? = Keyword.get(opts, :offline, false)
    unless offline?, do: require_credentials!()

    jev_opts = if offline?, do: [api_key: "offline", transport: FixtureTransport], else: [timeout: 15_000]
    jev = Models.init_decision_model!("typesafe:jev-1.13.0", jev_opts)
    IO.puts(if offline?, do: "OFFLINE: deterministic fixtures", else: "LIVE: TypeSafe + OpenAI")

    {:ok, result} =
      DecisionModel.invoke(jev, %{
        state: %{ticket: "Our checkout is down and customers cannot place orders."},
        questions: %{
          urgent: Question.noul(instructions: "Does `ticket` describe an urgent operational disruption?"),
          team:
            Question.choice(
              instructions: "Which team should investigate `ticket`?",
              criteria: %{
                engineering: "Service failures and software defects",
                billing: "Invoices and subscription charges"
              }
            ),
          severity:
            Question.score(
              instructions: "How severe is the functional impact in `ticket`?",
              criteria: ["Cosmetic only", "Degraded with workaround", "Customers blocked"]
            )
        }
      })

    IO.inspect(result.answers, label: "Standalone Jev decisions")

    IO.inspect(
      %{
        model: result.model,
        usage: result.usage,
        cost: result.metadata.cost,
        latency_ms: result.latency_ms,
        request_id: result.request_id
      },
      label: "Classifier accounting"
    )

    fast = chat_model("gpt-5.6-luna", offline?)
    powerful = chat_model("gpt-5.6-sol", offline?)

    router =
      TypeSafeModelRouter.new(
        classifier: jev,
        min_confidence: 0.8,
        choices: BeamWeaver.Examples.TypeSafeRouting.Prompts.choices(fast, powerful)
      )

    multiply =
      Tool.from_function!(
        name: "multiply",
        description: "Multiply two numbers exactly.",
        input_schema: %{type: :object, properties: %{a: %{type: :number}, b: %{type: :number}}, required: ["a", "b"]},
        handler: fn %{"a" => a, "b" => b}, _ ->
          IO.puts("Tool executed: multiply(#{a}, #{b})")
          to_string(a * b)
        end
      )

    {:ok, agent} =
      BWAgent.build(
        model: fast,
        tools: [multiply],
        middleware: [router],
        system_prompt: "Follow the user's task. Use the multiply tool for arithmetic. Be concise.",
        model_opts: [max_output_tokens: 1200],
        recursion_limit: 12
      )

    for prompt <- [@simple, @complex] do
      IO.puts("\nTask: #{prompt}")

      case BWAgent.invoke(agent, %{messages: [Message.user(prompt)]}) do
        {:ok, state} ->
          IO.inspect(state.model_route, label: "Model route (below 0.8 or on error: Luna)")
          IO.puts("Answer: " <> Message.text(List.last(state.messages)))

        {:error, error} ->
          raise "Agent failed: #{error.type}: #{error.message}"
      end
    end
  end

  defp chat_model(id, true), do: %FixtureChat{model: id}
  defp chat_model(id, false), do: Models.init_chat_model!("openai:#{id}", timeout: 60_000)

  defp require_credentials! do
    for {provider, names} <- [{:typesafe, "TYPESAFE_API_KEY (or TYPESAFE_API)"}, {:openai, "OPENAI_API_KEY"}] do
      if Config.get([provider, :api_key]) in [nil, ""],
        do:
          raise(
            ArgumentError,
            "Export #{names} before running. This live example does not load .env automatically; --offline uses fixtures."
          )
    end
  end
end

BeamWeaver.Examples.TypeSafeRouting.run(System.argv())
