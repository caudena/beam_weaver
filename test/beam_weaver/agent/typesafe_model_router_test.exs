defmodule BeamWeaver.Agent.TypeSafeModelRouterTest do
  use ExUnit.Case, async: true
  alias BeamWeaver.Agent, as: BWAgent
  alias BeamWeaver.Agent.Middleware.{ModelFallback, TypeSafeModelRouter}
  alias BeamWeaver.Agent.{ModelRequest, Usage}
  alias BeamWeaver.Core.{Error, Message, Tool}
  alias BeamWeaver.{Serialization, Stream}
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.TestSupport.OpenAIDecisions
  alias BeamWeaver.TestSupport.TypeSafe, as: Fixture
  alias BeamWeaver.Transport.Response

  defmodule Chat do
    @behaviour BeamWeaver.Core.ChatModel
    defstruct [:parent, :error, model: "base", tool: false, profile: %{structured_output: true}]
    def model_id(model), do: model.model

    def invoke(model, messages, opts) do
      send(model.parent, {:chat, model.model, messages, opts})

      if model.error do
        {:error, model.error}
      else
        has_result = Enum.any?(messages, &(&1.role == :tool))

        message =
          cond do
            opts[:response_format] -> Message.assistant(~s({"answer":"structured"}))
            model.tool and not has_result -> Message.assistant("", tool_calls: [%{id: "ping", name: "ping", args: %{}}])
            true -> Message.assistant(model.model)
          end

        {:ok, %{message | usage_metadata: %{input_tokens: 2, output_tokens: 1, total_tokens: 3}}}
      end
    end

    def stream_typed_events(model, messages, opts) do
      with {:ok, message} <- invoke(model, messages, opts),
           do: {:ok, [Stream.envelope(%Events.Message{message: message}), Stream.envelope(%Events.Done{})]}
    end
  end

  defp router(choice \\ "powerful", confidence \\ 0.9, opts \\ []) do
    parent = self()

    classifier =
      Keyword.get_lazy(opts, :classifier, fn ->
        Fixture.model(
          respond: fn request ->
            {:ok, Response.new(status: 200, body: Fixture.body(request.json["questions"], choice, confidence))}
          end
        )
      end)

    TypeSafeModelRouter.new(
      classifier: classifier,
      min_confidence: 0.8,
      choices: %{
        "fast" => %{
          model: %Chat{parent: parent, model: "fast", tool: opts[:tool] || false},
          criteria: "Localized tasks"
        },
        "powerful" => %{
          model: %Chat{parent: parent, model: "powerful", tool: opts[:tool] || false, error: opts[:error]},
          criteria: "Complex reasoning"
        }
      }
    )
  end

  defp agent(router, opts \\ []) do
    BWAgent.build(Keyword.merge([model: %Chat{parent: self()}, middleware: [router]], opts))
  end

  for {choice, confidence, expected} <- [
        {"fast", 0.9, "fast"},
        {"powerful", 0.8, "powerful"},
        {"powerful", 0.799, "base"}
      ] do
    @choice choice
    @confidence confidence
    @expected expected
    test "#{choice} at #{confidence} uses #{expected}" do
      assert {:ok, agent} = agent(router(@choice, @confidence))
      assert {:ok, result} = BWAgent.invoke(agent, %{messages: [Message.user("a task")]})
      assert List.last(result.messages).content == @expected
      assert result.model_route["confidence"] == @confidence
      assert result.model_route["accepted"] == @confidence >= 0.8
      assert_receive {:typesafe_request, request}
      assert request.json["state"]["message"]["content"] == "a task"
      refute_received {:typesafe_request, _}
    end
  end

  test "classifies only the latest user message and overwrites stale routing on a new run" do
    router = router()

    state = %{
      messages: [Message.user("old"), Message.assistant("previous answer"), Message.user("new")],
      model_route: %{"accepted" => true, "choice" => "fast"}
    }

    update = TypeSafeModelRouter.before_agent(router, state, %{})
    assert update.model_route["choice"] == "powerful"
    assert_receive {:typesafe_request, request}
    assert request.json["state"]["message"]["content"] == "new"
    refute inspect(request.json["state"]) =~ "previous answer"
  end

  test "missing, empty and unsupported input bypass classifier and do not keep an old route" do
    router = router()

    for messages <- [[], [Message.user("")], [Message.user([%{type: :image, url: "https://example.test/image"}])]] do
      update = TypeSafeModelRouter.before_agent(router, %{messages: messages, model_route: %{"accepted" => true}}, %{})
      refute update.model_route["accepted"]
    end

    refute_received {:typesafe_request, _}
  end

  defp choices do
    %{
      "fast" => %{model: %Chat{parent: self(), model: "fast"}, criteria: "Localized tasks"},
      "powerful" => %{model: %Chat{parent: self(), model: "powerful"}, criteria: "Complex reasoning"}
    }
  end

  @image %{type: :image, base64: "AAAA", mime_type: "image/png"}

  test "any decision model routes, such as OpenAI's, which gets the message's images" do
    route =
      TypeSafeModelRouter.new(
        classifier: OpenAIDecisions.model(choice: "powerful", confidence: 0.95),
        choices: choices()
      )

    message = Message.user(["Fix this chart", @image, %{type: :audio, data: "BBBB", mime_type: "audio/wav"}])
    update = TypeSafeModelRouter.before_agent(route, %{messages: [message]}, %{})
    assert %{"accepted" => true, "choice" => "powerful", "confidence" => 0.95} = update.model_route
    assert %Usage{input_tokens: 100, details: [%{provider: "openai", role: :classifier}]} = update.usage

    assert_receive {:decisions_request, request}
    assert [%{"type" => "choice", "name" => "choice", "choices" => [_, _]}] = request.json["questions"]

    assert [%{"content" => [%{"text" => before}, %{"type" => "input_image"}, %{"text" => rest}]}] =
             request.json["input"]

    assert %{"message" => %{"role" => "user", "content" => content}} =
             BeamWeaver.JSON.decode!(before <> "IMAGE" <> rest)

    assert Enum.map(content, & &1["text"]) == ["Fix this chart", "IMAGE", "[audio omitted]"]
  end

  test "a classifier that takes no images gets a placeholder, and one that refuses leaves the base model" do
    update = TypeSafeModelRouter.before_agent(router(), %{messages: [Message.user(["Fix this chart", @image])]}, %{})
    assert update.model_route["accepted"]
    assert_receive {:typesafe_request, request}

    assert request.json["state"]["message"]["content"] == [
             %{"type" => "text", "text" => "Fix this chart"},
             "[image omitted]"
           ]

    route = TypeSafeModelRouter.new(classifier: OpenAIDecisions.model(refuse: true), choices: choices())

    update =
      TypeSafeModelRouter.before_agent(
        route,
        %{messages: [Message.user("task")], model_route: %{"accepted" => true}},
        %{}
      )

    assert %{"accepted" => false, "reason" => "refused", "classifier_model" => "gpt-6-luna"} = update.model_route
    assert update.usage.input_tokens == 100
  end

  test "a message the provider refuses with its images is classified again as text only" do
    parent = self()

    classifier =
      OpenAIDecisions.model(
        respond: fn request ->
          send(parent, {:input, request.json["input"]})

          if inspect(request.json["input"]) =~ "input_image",
            do: {:ok, Response.new(status: 413, body: %{"error" => %{"message" => "Request too large."}})},
            else: {:ok, OpenAIDecisions.response(request.json["questions"], choice: "fast")}
        end
      )

    route = TypeSafeModelRouter.new(classifier: classifier, choices: choices())

    {update, log} =
      ExUnit.CaptureLog.with_log(fn ->
        TypeSafeModelRouter.before_agent(route, %{messages: [Message.user(["Fix this chart", @image])]}, %{})
      end)

    assert log =~ "refused (HTTP 413)"
    assert %{"accepted" => true, "choice" => "fast"} = update.model_route
    assert_receive {:input, with_image}
    assert inspect(with_image) =~ "input_image"
    assert_receive {:input, text_only}
    assert inspect(text_only) =~ "[image omitted]"
    refute_received {:input, _input}
  end

  test "the classifier and its question are checked when the router is built" do
    assert %BeamWeaver.OpenAI.DecisionModel{} =
             TypeSafeModelRouter.new(classifier: "openai:gpt-6-luna", choices: choices()).classifier

    structured = put_in(choices()["fast"].criteria, %{for: "small tasks"})

    assert_raise ArgumentError, ~r/2 to 255 distinct choices/, fn ->
      TypeSafeModelRouter.new(classifier: OpenAIDecisions.model(), choices: structured)
    end

    assert_raise ArgumentError, ~r/decision model/, fn ->
      TypeSafeModelRouter.new(classifier: %Chat{}, choices: choices())
    end
  end

  test "provider failures fall back and publish their reason" do
    classifier = Fixture.model(respond: fn _ -> {:error, BeamWeaver.Transport.Error.new(:timeout, "timeout")} end)
    parent = self()

    update =
      TypeSafeModelRouter.before_agent(
        router("fast", 1.0, classifier: classifier),
        %{messages: [Message.user("hello")]},
        %{stream_writer: fn event -> send(parent, {:event, event}) end}
      )

    assert update.model_route["reason"] == "classifier_error"
    assert update.model_route["error"]["type"] == "timeout"
    refute Map.has_key?(update, :usage)
    assert_receive {:event, %Events.Custom{payload: %{name: :model_route}}}
  end

  test "low-confidence classification contributes usage once without synthetic messages" do
    update = TypeSafeModelRouter.before_agent(router("fast", 0.2), %{messages: [Message.user("hello")]}, %{})
    assert %Usage{input_tokens: 100, output_tokens: 20, total_tokens: 120, model_calls: 1} = update.usage
    refute Map.has_key?(update, :messages)

    assert Usage.merge(update.usage, Usage.from_model_usage(%{input_tokens: 2, output_tokens: 1, total_tokens: 3})).total_tokens ==
             123
  end

  test "tool loop and typed streaming keep one selection and execute the tool once" do
    parent = self()

    tool =
      Tool.from_function!(
        name: "ping",
        description: "Ping",
        input_schema: %{type: :object},
        handler: fn _, _ ->
          send(parent, :executed)
          "pong"
        end
      )

    assert {:ok, agent} = agent(router("powerful", 0.9, tool: true), tools: [tool], model_opts: [stream: true])
    assert {:ok, stream} = BWAgent.stream_events(agent, %{messages: [Message.user("ping")]}, live: true)
    events = Enum.to_list(stream)
    refute Enum.any?(events, &match?(%{event: %Events.Error{}}, &1))
    assert_receive :executed
    refute_received :executed
    assert_receive {:chat, "powerful", _, _}
    assert_receive {:chat, "powerful", messages, _}
    assert Enum.any?(messages, &(&1.role == :tool and &1.content == "pong"))
    refute_received {:chat, _, _, _}
    assert_receive {:typesafe_request, _}
    refute_received {:typesafe_request, _}
  end

  test "serialization and resume reuse the stored route without classifying again" do
    router = router()
    update = TypeSafeModelRouter.before_agent(router, %{messages: [Message.user("task")]}, %{})
    assert {:ok, bytes} = Serialization.dump(update)
    assert {:ok, state} = Serialization.load(bytes)
    request = ModelRequest.new(model: %Chat{parent: self()}, state: state)
    assert {:ok, "powerful"} = TypeSafeModelRouter.wrap_model_call(router, request, &{:ok, &1.model.model})
    assert_receive {:typesafe_request, _}
    refute_received {:typesafe_request, _}
    changed = put_in(router.choices["powerful"].model.model, "changed")
    assert {:error, %{type: :invalid_model_route}} = TypeSafeModelRouter.wrap_model_call(changed, request, &{:ok, &1})
  end

  test "actual checkpoint continuation preserves routing and new input reclassifies" do
    router = router()
    saver = BeamWeaver.Checkpoint.ETS.new()
    config = %{configurable: %{thread_id: "jev-resume-#{System.unique_integer([:positive])}"}}
    assert {:ok, agent} = agent(router, checkpointer: saver, interrupt_before: [:model])
    assert {:interrupted, interrupt} = BWAgent.invoke(agent, %{messages: [Message.user("first")]}, config: config)
    assert_receive {:typesafe_request, _}
    assert {:ok, result} = BWAgent.resume(agent, nil, config: interrupt.config)
    assert result.model_route["choice"] == "powerful"
    refute_received {:typesafe_request, _}
    assert {:interrupted, _} = BWAgent.invoke(agent, %{messages: [Message.user("second")]}, config: config)
    assert_receive {:typesafe_request, request}
    assert request.json["state"]["message"]["content"] == "second"
  end

  test "router outside ModelFallback permits fallback after selected model failure" do
    route = router("powerful", 0.9, error: Error.new(:connection, "failed"))
    fallback = ModelFallback.new(fallbacks: [%Chat{parent: self(), model: "recovery"}])
    assert {:ok, agent} = agent(route, middleware: [route, fallback])
    assert {:ok, result} = BWAgent.invoke(agent, %{messages: [Message.user("task")]})
    assert List.last(result.messages).content == "recovery"
    assert_receive {:chat, "powerful", _, _}
    assert_receive {:chat, "recovery", _, _}
    assert_receive {:typesafe_request, _}
    refute_received {:typesafe_request, _}
  end

  test "conflicting model selectors fail, and the chosen model gets only the options it takes" do
    router = router()
    state = TypeSafeModelRouter.before_agent(router, %{messages: [Message.user("task")]}, %{})

    for opts <- [[model: "fast"], [extra_body: %{"model" => "fast"}], [extra_body: %{model: "fast"}]] do
      request = ModelRequest.new(model: %Chat{}, state: state, model_opts: opts)

      assert {:error, %{type: :conflicting_model_route}} =
               TypeSafeModelRouter.wrap_model_call(router, request, fn _ -> flunk("must not execute") end)
    end

    request =
      ModelRequest.new(
        model: %Chat{},
        state: state,
        model_opts: [model: "powerful", extra_body: %{"model" => "powerful", "keep" => true}]
      )

    assert {:ok, updated} = TypeSafeModelRouter.wrap_model_call(router, request, &{:ok, &1})
    assert updated.model.model == "powerful"
    refute Keyword.has_key?(updated.model_opts, :model)
    refute Keyword.has_key?(updated.model_opts, :extra_body)
  end

  test "the chosen model keeps its own credentials and gets the options its profile takes" do
    route =
      TypeSafeModelRouter.new(
        classifier: Fixture.model(),
        choices: %{
          "fast" => %{model: BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini"), criteria: "simple"},
          "powerful" => %{
            model: BeamWeaver.Models.init_chat_model!("anthropic:claude-haiku-4-5", api_key: "sk-ant-route"),
            criteria: "complex"
          }
        }
      )

    state = TypeSafeModelRouter.before_agent(route, %{messages: [Message.user("task")]}, %{})

    request =
      ModelRequest.new(
        model: BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini"),
        state: state,
        model_opts: [
          api_key: "sk-openai-agent",
          base_url: "https://openai.example",
          transport: BeamWeaver.Transport.ReqFinch,
          transport_opts: [retry: false],
          reasoning_effort: :low,
          temperature: 0.2,
          context: %{tenant: "acme"}
        ]
      )

    assert {:ok, updated} = TypeSafeModelRouter.wrap_model_call(route, request, &{:ok, &1})
    assert %BeamWeaver.Anthropic.ChatModel{api_key: "sk-ant-route"} = updated.model
    assert Enum.sort(updated.model_opts) == [context: %{tenant: "acme"}, temperature: 0.2]
  end

  test "routing changes the real OpenAI request model and preserves tool declarations" do
    parent = self()

    transport = fn request ->
      send(parent, {:openai_request, request})

      {:ok,
       Response.new(
         status: 200,
         body: %{
           "id" => "r",
           "status" => "completed",
           "output" => [
             %{"type" => "message", "role" => "assistant", "content" => [%{"type" => "output_text", "text" => "done"}]}
           ]
         }
       )}
    end

    fast =
      BeamWeaver.OpenAI.ChatModel.new(
        model: "gpt-5.6-luna",
        api_key: "fixture",
        transport: Fixture.Transport,
        transport_opts: [respond: transport]
      )

    powerful = %{fast | model: "gpt-5.6-sol"}

    route =
      TypeSafeModelRouter.new(
        classifier: Fixture.model(),
        choices: %{
          "fast" => %{model: fast, criteria: "simple"},
          "powerful" => %{model: powerful, criteria: "complex"}
        }
      )

    assert {:ok, agent} = BWAgent.build(model: fast, middleware: [route])
    assert {:ok, _} = BWAgent.invoke(agent, %{messages: [Message.user("complex task")]})
    assert_receive {:openai_request, request}
    assert request.json["model"] == "gpt-5.6-sol"
  end

  test "final separate structured response retains the route" do
    route = router()

    tool =
      Tool.from_function!(
        name: "ping",
        description: "Ping",
        input_schema: %{type: :object},
        handler: fn _, _ -> "pong" end
      )

    schema = %{type: :object, properties: %{answer: %{type: :string}}, required: [:answer]}
    format = BeamWeaver.Agent.StructuredOutput.provider(schema)
    assert {:ok, agent} = agent(route, tools: [tool], response_format: format)
    assert {:ok, result} = BWAgent.invoke(agent, %{messages: [Message.user("task")]})
    assert result.structured_response == %{"answer" => "structured"}
    assert_receive {:chat, "powerful", _, first_opts}
    assert_receive {:chat, "powerful", _, final_opts}
    refute first_opts[:response_format]
    assert final_opts[:response_format]
    refute_received {:chat, _, _, _}
    assert_receive {:typesafe_request, _}
    refute_received {:typesafe_request, _}
  end

  test "concurrent runs have independent route state" do
    classifier =
      Fixture.model(
        respond: fn request ->
          choice = request.json["state"]["message"]["content"]
          {:ok, Response.new(status: 200, body: Fixture.body(request.json["questions"], choice))}
        end
      )

    route = router("powerful", 0.9, classifier: classifier)
    assert {:ok, agent} = agent(route)
    choices = ["fast", "powerful", "fast", "powerful"]

    results =
      choices
      |> Task.async_stream(fn choice -> BWAgent.invoke(agent, %{messages: [Message.user(choice)]}) end)
      |> Enum.to_list()

    for {expected, {:ok, {:ok, result}}} <- Enum.zip(choices, results) do
      assert result.model_route["choice"] == expected
      assert List.last(result.messages).content == expected
    end

    assert Enum.all?(results, &match?({:ok, {:ok, _}}, &1))
    for _ <- 1..4, do: assert_receive({:typesafe_request, _})
    refute_received {:typesafe_request, _}
  end
end
