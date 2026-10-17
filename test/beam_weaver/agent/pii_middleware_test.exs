defmodule BeamWeaver.Agent.PIIMiddlewareTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.Middleware.PII
  alias BeamWeaver.Agent.Middleware.StructuredOutputRetry
  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Agent.ModelResponse
  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages
  alias BeamWeaver.Graph.Overwrite
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events

  test "detector helpers return typed matches with offsets" do
    assert [%{type: "email", value: "john.doe@example.com", start: 14, end: 34}] =
             PII.detect_email("Contact me at john.doe@example.com for more info.")

    assert [%{value: "alice@test.com"}, %{value: "bob@company.org"}] =
             PII.detect_email("Email alice@test.com or bob@company.org")

    assert [] = PII.detect_email("Invalid emails: @test.com, user@, user@domain")
    assert [] = PII.detect_email("This text has no email addresses.")

    assert [%{type: "credit_card", value: "4532-0151-1283-0366"}] =
             PII.detect_credit_card("Card: 4532-0151-1283-0366")

    assert [%{value: "5425 2334 3010 9903"}] =
             PII.detect_credit_card("Card: 5425 2334 3010 9903")

    assert [] = PII.detect_credit_card("Card: 1234567890123456")
    assert [] = PII.detect_credit_card("No cards here.")

    assert [%{type: "ip", value: "192.168.1.1"}] = PII.detect_ip("Server IP: 192.168.1.1")
    assert [%{value: "10.0.0.1"}, %{value: "8.8.8.8"}] = PII.detect_ip("IPs 10.0.0.1 8.8.8.8")
    assert [] = PII.detect_ip("Not an IP: 999.999.999.999")

    assert [%{type: "mac_address", value: "00:1A:2B:3C:4D:5E"}] =
             PII.detect_mac_address("MAC: 00:1A:2B:3C:4D:5E")

    assert [%{value: "00-1A-2B-3C-4D-5E"}] =
             PII.detect_mac_address("MAC: 00-1A-2B-3C-4D-5E")

    assert [%{value: "aa:bb:cc:dd:ee:ff"}] =
             PII.detect_mac_address("MAC: aa:bb:cc:dd:ee:ff")

    assert [] = PII.detect_mac_address("Partial: 00:1A:2B:3C")
    assert [] = PII.detect_mac_address("No MAC address here.")

    assert [%{value: "http://example.com"}] = PII.detect_url("Visit http://example.com now")

    assert [%{value: "https://secure.example.com/path"}] =
             PII.detect_url("Visit https://secure.example.com/path")

    assert [%{value: "www.example.com"}] = PII.detect_url("Visit www.example.com")
    assert [%{value: "example.com/path"}] = PII.detect_url("Go to example.com/path")

    assert [%{value: "http://test.com"}, %{value: "https://example.org"}] =
             PII.detect_url("Visit http://test.com and https://example.org")

    assert [] = PII.detect_url("No URLs here.")
    assert [] = PII.detect_url("The word example.com in prose")
  end

  test "redact, mask, and hash strategies are type-aware" do
    assert sanitize(
             PII.new(type: :email, strategy: :redact),
             Message.user("Email test@example.com")
           ) =~ "[REDACTED_EMAIL]"

    assert sanitize(
             PII.new(type: :email, strategy: :mask),
             Message.user("Email user@example.com")
           ) =~ "user@****.com"

    assert sanitize(
             PII.new(type: :ip, strategy: :mask),
             Message.user("IP 192.168.1.100")
           ) =~ "*.*.*.100"

    assert sanitize(
             PII.new(type: :credit_card, strategy: :mask),
             Message.user("Card 4532015112830366")
           ) =~ "************0366"

    assert sanitize(
             PII.new(type: :email, strategy: :redact),
             Message.user("a@test.com b@test.com")
           )
           |> String.split("[REDACTED_EMAIL]")
           |> length() == 3

    hash_one =
      sanitize(PII.new(type: :email, strategy: :hash), Message.user("Email test@example.com"))

    hash_two =
      sanitize(PII.new(type: :email, strategy: :hash), Message.user("Email test@example.com"))

    assert hash_one == hash_two
    assert hash_one =~ ~r/<email_hash:[a-f0-9]{8}>/
    refute hash_one =~ "test@example.com"
  end

  test "block strategy returns a tagged BeamWeaver error with match context" do
    middleware = PII.new(type: :email, strategy: :block)

    assert {:error,
            %Error{
              type: :pii_detected,
              details: %{pii_type: "email", matches: [%{value: "test@example.com"}]}
            }} =
             PII.before_model(
               middleware,
               %{messages: [Message.user("Email test@example.com")]},
               nil
             )

    assert {:error, %Error{details: %{matches: [_, _]}}} =
             PII.before_model(
               middleware,
               %{messages: [Message.user("Email alice@test.com and bob@test.com")]},
               nil
             )
  end

  test "input processing only edits the last user message" do
    middleware = PII.new(type: :email, strategy: :redact)

    assert %{messages: %Overwrite{} = overwrite} =
             PII.before_model(
               middleware,
               %{
                 messages: [
                   Message.user("Old old@example.com"),
                   Message.assistant("ok"),
                   Message.user("New new@example.com")
                 ]
               },
               nil
             )

    assert {:ok, [old, _assistant, new]} = Overwrite.get(overwrite)
    assert old.content == "Old old@example.com"
    assert new.content == "New [REDACTED_EMAIL]"
  end

  test "output and tool-result scopes are independent" do
    output_only =
      PII.new(type: :email, strategy: :redact, apply_to_input: false, apply_to_output: true)

    tool_only =
      PII.new(type: :ip, strategy: :mask, apply_to_input: false, apply_to_tool_results: true)

    assert is_nil(
             PII.before_model(
               output_only,
               %{messages: [Message.user("Email test@example.com")]},
               nil
             )
           )

    assert {:ok, %ModelResponse{messages: [%Message{content: "AI [REDACTED_EMAIL]"}]}} =
             edit_output(output_only, [Message.assistant("AI ai@example.com")])

    messages = [
      Message.user("Get server IP"),
      Message.assistant("", tool_calls: [%{id: "call_1", name: "lookup"}]),
      Message.tool("Server IP: 192.168.1.100", tool_call_id: "call_1")
    ]

    assert %{messages: %Overwrite{} = tool_update} =
             PII.before_model(tool_only, %{messages: messages}, nil)

    assert {:ok, [_user, _assistant, %Message{role: :tool, content: "Server IP: *.*.*.100"}]} =
             Overwrite.get(tool_update)

    tool_block =
      PII.new(type: :email, strategy: :block, apply_to_input: false, apply_to_tool_results: true)

    assert {:error, %Error{type: :pii_detected, details: %{pii_type: "email"}}} =
             PII.before_model(
               tool_block,
               %{
                 messages: [
                   Message.user("lookup"),
                   Message.assistant("", tool_calls: [%{id: "call_2", name: "lookup"}]),
                   Message.tool("User email: sensitive@example.com", tool_call_id: "call_2")
                 ]
               },
               nil
             )
  end

  test "one middleware can process both input and output scopes" do
    both = PII.new(type: :email, strategy: :redact, apply_to_input: true, apply_to_output: true)

    assert sanitize(both, Message.user("Email test@example.com")) == "Email [REDACTED_EMAIL]"

    assert {:ok, %ModelResponse{messages: [%Message{content: "AI [REDACTED_EMAIL]"}]}} =
             edit_output(both, [Message.assistant("AI ai@example.com")])

    assert is_nil(PII.before_model(both, %{messages: [Message.user("No PII here")]}, nil))
    assert is_nil(PII.before_model(both, %{messages: []}, nil))
  end

  test "an output rule edits only the text of a reply" do
    middleware = PII.new(type: :email, apply_to_input: false, apply_to_output: true)
    email = "ada@example.com"

    reply =
      Message.assistant(
        [
          ContentBlock.text("Mail #{email}."),
          %{type: :reasoning, reasoning: "The customer is #{email}.", signature: "c2ln"},
          %{type: :tool_call, id: "call_1", name: "email_user", args: %{"to" => email}}
        ],
        tool_calls: [%{id: "call_1", name: "email_user", args: %{"to" => email}}],
        metadata: %{parsed: %{"to" => email}},
        response_metadata: %{raw_provider_response: %{"output" => [%{"text" => "Mail #{email}."}]}},
        artifacts: [%{"to" => email}]
      )

    assert {:ok, %ModelResponse{messages: [edited], structured_response: %{"to" => ^email}}} =
             edit_output(middleware, [reply], %{"to" => email})

    assert [%ContentBlock.Text{text: "Mail [REDACTED_EMAIL]."} | rest] = edited.content
    assert rest == tl(reply.content)
    assert %{edited | content: reply.content} == reply
  end

  test "a tool-result rule edits the text of tool results and leaves the data the tool keeps" do
    middleware = PII.new(type: :email, apply_to_input: false, apply_to_tool_results: true)
    record = %{"email" => "ada@example.com"}

    result =
      Message.tool("Found ada@example.com.", tool_call_id: "call_1", metadata: %{artifact: record}, artifacts: [record])

    messages = [
      Message.user("look it up"),
      Message.assistant("", tool_calls: [%{id: "call_1", name: "lookup"}]),
      result
    ]

    assert %{messages: %Overwrite{} = overwrite} = PII.before_model(middleware, %{messages: messages}, nil)
    assert {:ok, [_user, _assistant, edited]} = Overwrite.get(overwrite)
    assert edited == %{result | content: "Found [REDACTED_EMAIL]."}
  end

  test "stream transform redacts token PII spanning chunk boundaries" do
    {transform, state} = PII.stream_transform(type: :email, strategy: :redact)

    assert {{:ok, %Envelope{event: %Events.Token{text: ""}}}, state} =
             transform.(%Envelope{event: %Events.Token{text: "contact ada@"}}, state)

    assert {{:ok, %Envelope{event: %Events.Token{text: ""}}}, state} =
             transform.(%Envelope{event: %Events.Token{text: "example.com now"}}, state)

    assert {{:ok,
             [
               %Envelope{event: %Events.Token{text: "contact [REDACTED_EMAIL] now"}},
               %Envelope{event: %Events.Done{}}
             ]}, _state} = transform.(%Envelope{event: %Events.Done{}}, state)
  end

  defmodule StreamingAgent do
    use BeamWeaver.Agent

    model "fake:chat", stream: true, responses: ["Your order shipped. Tracking went to ada@example.com."]
  end

  test "stream transform redacts a whole agent stream without repeating text" do
    {transform, state} = PII.stream_transform(type: :email, strategy: :redact)
    {:ok, events} = StreamingAgent.stream_events(%{messages: ["Where is my order?"]}, live: true)

    redacted =
      events
      |> Stream.transform(state, fn envelope, state ->
        {{:ok, out}, state} = transform.(envelope, state)
        {List.wrap(out), state}
      end)
      |> Enum.to_list()

    expected = "Your order shipped. Tracking went to [REDACTED_EMAIL]."
    assert Enum.map_join(for(%{event: %Events.Token{text: text}} <- redacted, do: text), & &1) == expected

    assert Enum.map_join(for(%{event: %Events.MessageChunk{chunk: chunk}} <- redacted, do: chunk.content), & &1) ==
             expected
  end

  test "stream transform ends a model call's text when its Done arrives" do
    {transform, state} = PII.stream_transform(type: :email, strategy: :redact)
    first = %Envelope{event: %Events.Token{text: "first ada@example.com"}, run_id: "run", task_id: "first"}
    second = %Envelope{event: %Events.Token{text: "second bob@"}, run_id: "run", task_id: "second"}

    {{:ok, _}, state} = transform.(first, state)
    {{:ok, _}, state} = transform.(second, state)

    assert {{:ok, [%Envelope{event: %Events.Token{text: "first [REDACTED_EMAIL]"}}, %Envelope{event: %Events.Done{}}]},
            state} = transform.(%Envelope{event: %Events.Done{}, run_id: "run", task_id: "first"}, state)

    {{:ok, _}, state} = transform.(%{second | event: %Events.Token{text: "example.com"}}, state)

    assert {{:ok, [%Envelope{event: %Events.Token{text: "second [REDACTED_EMAIL]"}}, _done]}, []} =
             transform.(%Envelope{event: %Events.Done{}, run_id: "run", task_id: "second"}, state)
  end

  test "stream transform ends a failed model call's text before the next call's" do
    {transform, state} = PII.stream_transform(type: :email, strategy: :redact)
    token = &%Envelope{event: %Events.Token{text: &1}, run_id: "run", task_id: "model"}
    failure = %Events.Debug{payload: %{type: :model_call_failed, error: Error.new(:server_error, "Busy")}}
    failed = %Envelope{event: failure, run_id: "run", task_id: "model"}

    {{:ok, _}, state} = transform.(token.("Mail ada@exa"), state)

    assert {{:ok, [%Envelope{event: %Events.Token{text: "Mail ada@exa"}}, ^failed]}, []} = transform.(failed, state)
  end

  test "stream transform redacts reasoning and tool-call arguments split across chunks" do
    {transform, state} = PII.stream_transform(type: :email, strategy: :redact)

    reasoning =
      &%Envelope{event: %Events.MessageChunk{chunk: Messages.ai_chunk([%{type: :reasoning, reasoning: &1, index: 0}])}}

    args = &%Envelope{event: %Events.ToolCallChunk{chunk: Messages.tool_call_chunk(index: 0, args: &1)}}

    chunk_args =
      &%Envelope{
        event: %Events.MessageChunk{
          chunk: Messages.ai_chunk("", tool_call_chunks: [Messages.tool_call_chunk(index: 0, args: &1)])
        }
      }

    events = [
      reasoning.("Write to ada@"),
      reasoning.("example.com."),
      args.(~s({"to":"grace@)),
      args.(~s(example.com"})),
      chunk_args.(~s({"to":"bob@)),
      chunk_args.(~s(example.com"})),
      %Envelope{event: %Events.Done{}}
    ]

    out = run_stream(transform, state, events)

    assert Enum.join(for %{event: %Events.MessageChunk{chunk: %{content: [%{reasoning: text}]}}} <- out, do: text) ==
             "Write to [REDACTED_EMAIL]."

    assert Enum.join(for %{event: %Events.ToolCallChunk{chunk: chunk}} <- out, do: chunk.args) ==
             ~s({"to":"[REDACTED_EMAIL]"})

    assert Enum.join(for %{event: %Events.MessageChunk{chunk: %{tool_call_chunks: [chunk]}}} <- out, do: chunk.args) ==
             ~s({"to":"[REDACTED_EMAIL]"})

    refute inspect(out) =~ "example.com"
  end

  # Chunks without an index are calls of their own, so nothing is held back
  # from one to the next.
  test "stream transform edits each tool-call chunk without an index on its own" do
    {transform, state} = PII.stream_transform(type: :email, strategy: :redact)
    chunk = &%Envelope{event: %Events.ToolCallChunk{chunk: Messages.tool_call_chunk(name: &1, args: &2)}}

    events = [
      chunk.("email_user", ~s({"to":"ada@example.com"})),
      chunk.("log", ~s({"n":1})),
      %Envelope{event: %Events.Done{}}
    ]

    assert [{"email_user", ~s({"to":"[REDACTED_EMAIL]"})}, {"log", ~s({"n":1})}] =
             for(
               %{event: %Events.ToolCallChunk{chunk: chunk}} <- run_stream(transform, state, events),
               do: {chunk.name, chunk.args}
             )
  end

  test "stream transform redacts tool events and state snapshots, and leaves custom events" do
    {transform, state} = PII.stream_transform(type: :email, strategy: :redact)
    result = Message.tool("Found ada@example.com.", tool_call_id: "call_1")

    events = [
      %Envelope{
        event: %Events.ToolStart{tool_call_id: "call_1", tool_name: "lookup", input: %{"email" => "ada@example.com"}}
      },
      %Envelope{event: %Events.ToolDelta{tool_call_id: "call_1", delta: "Found ada@"}},
      %Envelope{event: %Events.ToolDelta{tool_call_id: "call_1", delta: "example.com."}},
      %Envelope{event: %Events.ToolFinish{tool_call_id: "call_1", output: result}},
      %Envelope{event: %Events.ToolError{tool_call_id: "call_2", message: "No customer ada@example.com"}},
      %Envelope{event: %Events.GraphValue{value: %{messages: [result], notes: ["ada@example.com"]}}},
      %Envelope{event: %Events.Custom{payload: %{"email" => "ada@example.com"}}}
    ]

    out = Enum.map(run_stream(transform, state, events), & &1.event)
    redacted = %{result | content: "Found [REDACTED_EMAIL]."}

    assert [
             %Events.ToolStart{input: %{"email" => "[REDACTED_EMAIL]"}},
             %Events.ToolDelta{delta: ""},
             %Events.ToolDelta{delta: ""},
             %Events.ToolDelta{delta: "Found [REDACTED_EMAIL]."},
             %Events.ToolFinish{output: ^redacted},
             %Events.ToolError{message: "No customer [REDACTED_EMAIL]"},
             %Events.GraphValue{value: %{messages: [^redacted], notes: ["[REDACTED_EMAIL]"]}},
             %Events.Custom{payload: %{"email" => "ada@example.com"}}
           ] = out
  end

  test "stream transform redacts a whole message's content and tool-call arguments, and leaves its metadata" do
    {transform, state} = PII.stream_transform(type: :email, strategy: :redact)

    message =
      Message.assistant(
        [ContentBlock.text("Mail ada@example.com"), %{type: :reasoning, reasoning: "ada@example.com asked"}],
        tool_calls: [%{id: "call_1", name: "email_user", args: %{"to" => "grace@example.com"}}],
        response_metadata: %{raw_provider_response: %{"content" => [%{"text" => "Mail ada@example.com"}]}}
      )

    assert {{:ok, %Envelope{event: %Events.Message{message: redacted}}}, []} =
             transform.(%Envelope{event: %Events.Message{message: message}}, state)

    assert [%ContentBlock.Text{text: "Mail [REDACTED_EMAIL]"}, reasoning] = redacted.content
    assert reasoning.reasoning == "[REDACTED_EMAIL] asked"
    assert [%{args: %{"to" => "[REDACTED_EMAIL]"}}] = redacted.tool_calls
    assert redacted.response_metadata == message.response_metadata
  end

  test "custom regex and callable detectors normalize values for all strategies" do
    regex = PII.new(type: "api_key", detector: "sk-[a-zA-Z0-9]{32}", strategy: :redact)

    assert "Key [REDACTED_API_KEY]" =
             sanitize(regex, Message.user("Key sk-abcdefghijklmnopqrstuvwxyz123456"))

    callable =
      PII.new(
        type: "indian_phone",
        detector: fn content ->
          Regex.scan(~r/\+91[\s.-]?\d{10}/, content, return: :index)
          |> Enum.map(fn [{start, length}] ->
            %{text: binary_part(content, start, length), start: start, end: start + length}
          end)
        end,
        strategy: :hash
      )

    content = sanitize(callable, Message.user("Call +91 9876543210"))
    assert content =~ ~r/<indian_phone_hash:[a-f0-9]{8}>/
    refute content =~ "+91 9876543210"

    masked =
      callable
      |> Map.put(:strategy, :mask)
      |> sanitize(Message.user("Call +91 9876543210"))

    assert masked =~ "****3210"
    refute masked =~ "+91 9876543210"

    confidential =
      PII.new(
        type: "confidential",
        detector: fn content ->
          case :binary.match(content, "CONFIDENTIAL") do
            {start, length} ->
              [%{type: "confidential", value: "CONFIDENTIAL", start: start, end: start + length}]

            :nomatch ->
              []
          end
        end,
        strategy: :redact
      )

    assert sanitize(confidential, Message.user("This is CONFIDENTIAL information")) ==
             "This is [REDACTED_CONFIDENTIAL] information"
  end

  test "multiple middleware rules can be applied sequentially" do
    message = Message.user("Email test@example.com, IP: 192.168.1.1")
    email = PII.new(type: :email, strategy: :redact)
    ip = PII.new(type: :ip, strategy: :mask)

    first = sanitize(email, message)
    second = sanitize(ip, %{message | content: first})

    assert second =~ "[REDACTED_EMAIL]"
    assert second =~ "*.*.*.1"
    refute second =~ "test@example.com"
    refute second =~ "192.168.1.1"
  end

  test "one custom detector can redact multiple PII types" do
    combined =
      PII.new(
        type: "email_or_ip",
        detector: fn content -> PII.detect_email(content) ++ PII.detect_ip(content) end,
        strategy: :redact
      )

    content = sanitize(combined, Message.user("Email: test@example.com, IP: 10.0.0.1"))

    refute content =~ "test@example.com"
    refute content =~ "10.0.0.1"
    assert content =~ "[REDACTED_EMAIL]"
    assert content =~ "[REDACTED_IP]"
  end

  test "unknown builtin type requires an explicit detector" do
    assert_raise ArgumentError, ~r/Unknown PII type/, fn ->
      PII.new(type: "unknown_type", strategy: :redact)
    end
  end

  test "strategy config is atom-only" do
    assert_raise ArgumentError, ~s(strategy must be an atom, got "redact"; use :redact), fn ->
      PII.new(type: :email, strategy: "redact")
    end
  end

  test "the text blocks of multimodal messages are redacted in input, tool results and output" do
    middleware = PII.new(type: :email, apply_to_input: true, apply_to_output: true, apply_to_tool_results: true)
    image = ContentBlock.image(url: "https://example.com/receipt.png")

    user =
      Message.user([
        %{type: "text", text: "mail me at ada@example.com"},
        image,
        "or grace@example.com"
      ])

    assert %{messages: %Overwrite{} = overwrite} = PII.before_model(middleware, %{messages: [user]}, nil)

    assert {:ok,
            [
              %Message{
                content: [
                  %{type: :text, text: "mail me at [REDACTED_EMAIL]"},
                  ^image,
                  %ContentBlock.Text{text: "or [REDACTED_EMAIL]"}
                ]
              }
            ]} = Overwrite.get(overwrite)

    messages = [
      Message.user("look it up"),
      Message.assistant("", tool_calls: [%{id: "call_1", name: "lookup"}]),
      Message.tool([ContentBlock.text("owner: ada@example.com")], tool_call_id: "call_1")
    ]

    assert %{messages: %Overwrite{} = overwrite} =
             PII.before_model(%{middleware | apply_to_input: false}, %{messages: messages}, nil)

    assert {:ok,
            [_user, _assistant, %Message{role: :tool, content: [%ContentBlock.Text{text: "owner: [REDACTED_EMAIL]"}]}]} =
             Overwrite.get(overwrite)

    reply = Message.assistant([ContentBlock.text("Sure, ada@example.com noted."), image])

    assert {:ok,
            %ModelResponse{
              messages: [%Message{content: [%ContentBlock.Text{text: "Sure, [REDACTED_EMAIL] noted."}, ^image]}]
            }} =
             edit_output(middleware, [reply])
  end

  test "the output rule edits every message of the model call's reply and blocks a failed answer" do
    middleware = PII.new(type: :email, apply_to_input: false, apply_to_output: true)

    reply = [
      Message.assistant("first draft for ada@example.com"),
      Message.user("Try again."),
      Message.assistant("final answer for grace@example.com")
    ]

    assert {:ok, %ModelResponse{messages: messages}} = edit_output(middleware, reply)

    assert Enum.map(messages, &Message.text/1) == [
             "first draft for [REDACTED_EMAIL]",
             "Try again.",
             "final answer for [REDACTED_EMAIL]"
           ]

    failed =
      Error.new(:structured_output_validation_error, "invalid", %{failed_reply: Message.assistant("ada@example.com")})

    request = ModelRequest.new(messages: [Message.user("hello")])

    assert {:error, %Error{details: %{failed_reply: %Message{content: "[REDACTED_EMAIL]"}}}} =
             PII.wrap_model_call(middleware, request, fn _request -> {:error, failed} end)

    assert {:error, %Error{type: :pii_detected}} =
             PII.wrap_model_call(%{middleware | strategy: :block}, request, fn _request -> {:error, failed} end)
  end

  defmodule Triage do
    use BeamWeaver.Schema

    field :category, :string
    field :priority, :string
  end

  # The first answer fails the schema; StructuredOutputRetry keeps it in the
  # thread next to the feedback and the second answer.
  defp structured_retry_agent(middleware) do
    BeamWeaver.Agent.build(
      model: "fake:chat",
      model_opts: [
        responses: [
          BeamWeaver.Models.FakeChatModel.final(%{category: "email ada@example.com back"}),
          BeamWeaver.Models.FakeChatModel.final(%{category: "shipping", priority: "high"})
        ]
      ],
      middleware: middleware,
      response_format: Triage
    )
  end

  test "the failed answer StructuredOutputRetry keeps is redacted, in either middleware order" do
    pii = {PII, type: :email, apply_to_input: false, apply_to_output: true}

    for middleware <- [[StructuredOutputRetry, pii], [pii, StructuredOutputRetry]] do
      {:ok, agent} = structured_retry_agent(middleware)
      assert {:ok, result} = BeamWeaver.Agent.invoke(agent, %{messages: ["My order never arrived"]})

      saved = Enum.map(result.messages, &Message.text/1)
      assert Enum.any?(saved, &(&1 =~ "email [REDACTED_EMAIL] back"))
      refute Enum.any?(saved, &(&1 =~ "ada@example.com"))
      assert result.structured_response == %{"category" => "shipping", "priority" => "high"}
    end
  end

  defmodule OutputRuleAgent do
    use BeamWeaver.Agent

    model "fake:chat", responses: ["Write to ada@example.com."]
    middleware [{PII, type: :email, apply_to_input: false, apply_to_output: true}]
  end

  test "no checkpoint of the thread holds the unredacted reply" do
    saver = BeamWeaver.Checkpoint.ETS.new()
    opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "pii-output"}}]

    assert {:ok, result} = OutputRuleAgent.invoke(%{messages: ["hi"]}, opts)
    assert List.last(result.messages).content == "Write to [REDACTED_EMAIL]."

    {:ok, graph} = BeamWeaver.Agent.compiled_graph(OutputRuleAgent, checkpointer: saver)
    history = BeamWeaver.Graph.Compiled.get_state_history(graph, opts[:config])

    assert length(history) > 1
    refute Enum.any?(history, fn snapshot -> inspect(snapshot.values) =~ "ada@example.com" end)
  end

  defmodule Contact do
    use BeamWeaver.Schema

    field :category, :string
    field :email, :string
  end

  defmodule LookupOrder do
    use BeamWeaver.Tool

    name "lookup_order"
    description "Look up an order."

    schema do
      field :order_id, :string
    end

    @impl true
    def invoke(_tool, %{"order_id" => order_id}, _opts), do: {:ok, "Order #{order_id} is lost."}
  end

  # With tools, the structured response comes from one more model call after
  # the tool loop; without them, from the agent's only model call.
  defp structured_agent(tools, pii) do
    final = BeamWeaver.Models.FakeChatModel.final(%{category: "shipping", email: "ada@example.com"})

    responses =
      if tools == [],
        do: [final],
        else: [BeamWeaver.Models.FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1"}), "It's lost.", final]

    BeamWeaver.Agent.build(
      model: "fake:chat",
      model_opts: [responses: responses],
      tools: tools,
      middleware: [pii],
      response_format: Contact
    )
  end

  test "an output rule edits the text of an agent's structured answer and leaves the structured response" do
    {:ok, agent} = structured_agent([LookupOrder], {PII, type: :email, apply_to_input: false, apply_to_output: true})
    assert {:ok, result} = BeamWeaver.Agent.invoke(agent, %{messages: ["Where is A-1?"]})

    assert result.structured_response == %{"category" => "shipping", "email" => "ada@example.com"}
    assert Message.text(List.last(result.messages)) == ~s({"category":"shipping","email":"[REDACTED_EMAIL]"})
  end

  describe "overlapping detector matches (a URL containing an IP address)" do
    test "redact does not crash and removes both the URL and embedded IP" do
      middleware = PII.new(detectors: [:url, :ip], strategy: :redact)
      content = sanitize(middleware, Message.user("Visit http://192.168.1.1/path now"))

      refute content =~ "192.168.1.1"
      refute content =~ "http://192.168.1.1"
    end

    test "mask does not crash and removes the embedded IP" do
      middleware = PII.new(detectors: [:url, :ip], strategy: :mask)
      content = sanitize(middleware, Message.user("Visit http://192.168.1.1/path now"))

      refute content =~ "192.168.1.1"
    end

    test "hash does not crash and removes the embedded IP" do
      middleware = PII.new(detectors: [:url, :ip], strategy: :hash)
      content = sanitize(middleware, Message.user("Visit http://192.168.1.1/path now"))

      refute content =~ "192.168.1.1"
    end

    test "mask on a URL spanning the whole string does not raise ArgumentError" do
      middleware = PII.new(detectors: [:url, :ip], strategy: :mask)
      content = sanitize(middleware, Message.user("http://192.168.1.1/aaaa"))

      refute content =~ "192.168.1.1"
    end
  end

  # The output rule edits the reply of the model call it wraps.
  defp edit_output(middleware, messages, structured_response \\ nil) do
    request = ModelRequest.new(messages: [Message.user("hello")])
    response = %ModelResponse{messages: messages, structured_response: structured_response}
    PII.wrap_model_call(middleware, request, fn _request -> {:ok, response} end)
  end

  defp run_stream(transform, state, events) do
    {out, _state} =
      Enum.flat_map_reduce(events, state, fn event, state ->
        {{:ok, out}, state} = transform.(event, state)
        {List.wrap(out), state}
      end)

    out
  end

  defp sanitize(middleware, message) do
    assert %{messages: %Overwrite{} = overwrite} =
             PII.before_model(middleware, %{messages: [message]}, nil)

    assert {:ok, [%Message{content: content}]} = Overwrite.get(overwrite)
    content
  end
end
