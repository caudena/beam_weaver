defmodule BeamWeaver.Agent.RuntimeBuilderTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent
  alias BeamWeaver.Agent.Built
  alias BeamWeaver.Agent.Middleware.DynamicPrompt
  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Anthropic.Messages, as: AnthropicMessages
  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Stream
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events

  defmodule ToolCallingModel do
    @behaviour BeamWeaver.Core.ChatModel

    defstruct calls: []

    @impl true
    def invoke(%__MODULE__{calls: calls}, messages, _opts) do
      tool_messages = Enum.filter(messages, &(&1.role == :tool))

      if length(tool_messages) < length(calls) do
        call = Enum.at(calls, length(tool_messages))
        {:ok, Message.assistant("", tool_calls: [call])}
      else
        {:ok, Message.assistant("done")}
      end
    end
  end

  defmodule RecordingContextModel do
    @behaviour BeamWeaver.Core.ChatModel

    defstruct [:parent]

    @impl true
    def invoke(%__MODULE__{parent: parent}, messages, opts) do
      send(parent, {:runtime_builder_model_call, messages, opts})
      {:ok, Message.assistant("ok")}
    end
  end

  defmodule TypedStreamingModel do
    @behaviour BeamWeaver.Core.ChatModel

    defstruct []

    @impl true
    def invoke(%__MODULE__{}, _messages, _opts) do
      {:ok, Message.assistant("invoke")}
    end

    @impl true
    def stream_typed_events(%__MODULE__{}, _messages, _opts) do
      {:ok,
       [
         Stream.envelope(%Events.MessageChunk{
           chunk: Messages.ai_chunk([ContentBlock.reasoning("thinking")], id: "rs_1")
         }),
         Stream.envelope(%Events.MessageChunk{chunk: Messages.ai_chunk("", id: "msg_empty")}),
         Stream.envelope(%Events.Token{text: "answer"}),
         Stream.envelope(%Events.Done{})
       ]}
    end
  end

  defmodule UnsupportedTypedStreamingModel do
    @behaviour BeamWeaver.Core.ChatModel

    defstruct []

    @impl true
    def invoke(%__MODULE__{}, _messages, _opts) do
      {:ok, Message.assistant("invoke")}
    end

    @impl true
    def stream_typed_events(%__MODULE__{}, _messages, _opts) do
      {:error,
       BeamWeaver.Core.Error.new(
         :unsupported_feature,
         "provider does not support typed stream events"
       )}
    end

    def stream_response(%__MODULE__{}, _messages, _opts) do
      {:ok, Message.assistant("stream response")}
    end
  end

  defmodule SignedTypedStreamingModel do
    @behaviour BeamWeaver.Core.ChatModel

    defstruct [:parent]

    @impl true
    def invoke(%__MODULE__{}, _messages, _opts), do: {:ok, Message.assistant("invoke")}

    @impl true
    def stream_typed_events(%__MODULE__{parent: parent}, messages, _opts) do
      send(parent, {:signed_typed_stream_input, messages})

      fragments = [
        %{
          index: 0,
          type: :reasoning,
          reasoning: "",
          raw_provider_block: %{"type" => "thinking", "thinking" => "", "signature" => ""}
        },
        %{
          index: 0,
          type: :reasoning,
          reasoning: "Need tools",
          raw_provider_block: %{"type" => "thinking_delta", "thinking" => "Need tools"}
        },
        %{
          index: 0,
          type: :reasoning,
          raw_provider_block: %{"type" => "signature_delta", "signature" => "signed-thinking"}
        }
      ]

      {:ok,
       Enum.map(fragments, fn fragment ->
         Stream.envelope(%Events.MessageChunk{chunk: Messages.ai_chunk([fragment])})
       end) ++
         [
           Stream.envelope(%Events.Token{text: "answer"}),
           Stream.envelope(%Events.Done{})
         ]}
    end
  end

  defmodule DynamicModelMiddleware do
    use BeamWeaver.Agent.Middleware

    defstruct [:parent]

    def wrap_model_call(%__MODULE__{parent: parent}, %ModelRequest{} = request, handler) do
      send(
        parent,
        {:dynamic_model_state, request.state.messages, request.runtime.context.user_id}
      )

      request
      |> ModelRequest.override(model: %RecordingContextModel{parent: request.runtime.context.parent})
      |> handler.()
    end
  end

  test "builds a dynamic agent through the same graph-backed loop as the DSL" do
    tool =
      Tool.from_function!(
        name: "adder",
        description: "Add two numbers",
        input_schema: %{"required" => ["a", "b"]},
        handler: fn %{"a" => a, "b" => b}, _opts -> a + b end
      )

    model = %ToolCallingModel{
      calls: [%{id: "call-add", name: "adder", args: %{"a" => 2, "b" => 4}}]
    }

    assert {:ok, %Built{} = agent} =
             Agent.build(
               name: "dynamic_calculator",
               model: model,
               tools: [tool],
               system_prompt: "You are a calculator."
             )

    assert {:ok, %{messages: messages}} =
             Agent.invoke(agent, %{messages: [Message.user("2+4?")]}, [])

    assert [
             %Message{role: :user, content: "2+4?"},
             %Message{role: :assistant, tool_calls: [%{name: "adder"}]},
             %Message{role: :tool, content: "6", name: "adder"},
             %Message{role: :assistant, content: "done"}
           ] = messages
  end

  test "validates runtime input schemas" do
    assert {:ok, agent} =
             Agent.build(
               model: %ToolCallingModel{},
               input_schema: %{messages: %{type: :list, required: true}}
             )

    assert {:error, %{type: :invalid_agent_input}} = Agent.invoke(agent, %{}, [])
  end

  test "runtime builder accepts string-keyed dynamic specs" do
    assert {:ok, %Built{} = agent} =
             Agent.build(%{
               "name" => "runtime_agent",
               "model" => %ToolCallingModel{},
               "tools" => [],
               "system_prompt" => "Answer directly."
             })

    assert agent.spec.name == "runtime_agent"

    assert {:ok, %{messages: [%Message{role: :user}, %Message{content: "done"}]}} =
             Agent.invoke(agent, %{messages: [Message.user("hello")]})
  end

  test "runtime builder projects string-keyed public input to atom-key agent state" do
    parent = self()

    assert {:ok, %Built{} = agent} =
             Agent.build(
               model: %RecordingContextModel{parent: parent},
               tools: []
             )

    assert {:ok, %{messages: [%Message{role: :user}, %Message{content: "ok"}] = messages} = state} =
             Agent.invoke(agent, %{"messages" => [Message.user("hello")], "external" => "raw"})

    refute Map.has_key?(state, "messages")
    assert [%Message{role: :user, content: "hello"}, %Message{role: :assistant}] = messages
    assert_receive {:runtime_builder_model_call, [%Message{role: :user, content: "hello"}], _opts}
  end

  test "built agents expose typed event streaming" do
    refute function_exported?(Agent, :stream, 3)

    assert {:ok, %Built{} = agent} =
             Agent.build(%{
               "name" => "runtime_stream_agent",
               "model" => %ToolCallingModel{},
               "tools" => [],
               "system_prompt" => "Answer directly."
             })

    assert {:ok, events} = Agent.stream_events(agent, %{messages: [Message.user("hello")]})

    assert Enum.any?(
             events,
             &match?(
               %Envelope{event: %Events.GraphUpdate{update: %{"model" => %{messages: [_]}}}},
               &1
             )
           )

    assert %Envelope{event: %Events.Debug{payload: %{type: :producer_stop}}} = List.last(events)
  end

  test "built agents forward model typed reasoning events while preserving final output" do
    assert {:ok, %Built{} = agent} =
             Agent.build(
               name: "runtime_typed_stream_agent",
               model: %TypedStreamingModel{},
               tools: []
             )

    assert {:ok, stream} =
             Agent.stream_events(
               agent,
               %{messages: [Message.user("hello")]},
               live: true,
               stream_mode: :events,
               model_opts: [stream: true]
             )

    events = Enum.to_list(stream)

    assert Enum.any?(
             events,
             &match?(
               %Envelope{
                 event: %Events.MessageChunk{
                   chunk: %{content: [%ContentBlock.Reasoning{reasoning: "thinking"}]}
                 }
               },
               &1
             )
           )

    assert Enum.any?(
             events,
             &match?(
               %Envelope{event: %Events.GraphUpdate{update: %{"model" => %{messages: [%Message{content: "answer"}]}}}},
               &1
             )
           )
  end

  test "built agents retain provider-signed thinking for the next model turn" do
    assert {:ok, %Built{} = agent} =
             Agent.build(
               name: "runtime_signed_stream_agent",
               model: %SignedTypedStreamingModel{parent: self()},
               tools: []
             )

    assert {:ok, stream} =
             Agent.stream_events(
               agent,
               %{messages: [Message.user("hello")]},
               live: true,
               stream_mode: :events,
               model_opts: [stream: true]
             )

    final_message =
      stream
      |> Enum.find_value(fn
        %Envelope{
          event: %Events.GraphUpdate{
            update: %{"model" => %{messages: [%Message{} = message]}}
          }
        } ->
          message

        _event ->
          nil
      end)

    assert Message.text(final_message) == "answer"

    assert [reasoning, %ContentBlock.Text{text: "answer"}] = final_message.content
    assert reasoning.reasoning == "Need tools"
    assert reasoning.raw_provider_block["signature"] == "signed-thinking"

    assert_received {:signed_typed_stream_input, [%Message{role: :user, content: "hello"}]}

    second_state = %{
      messages: [Message.user("hello"), final_message, Message.user("follow up")]
    }

    assert {:ok, second_stream} =
             Agent.stream_events(agent, second_state,
               live: true,
               stream_mode: :events,
               model_opts: [stream: true]
             )

    _events = Enum.to_list(second_stream)

    assert_received {:signed_typed_stream_input,
                     [
                       %Message{role: :user, content: "hello"},
                       %Message{role: :assistant} = replayed,
                       %Message{role: :user, content: "follow up"}
                     ]}

    assert {:ok, {nil, [%{"role" => "assistant", "content" => replayed_content}]}} =
             AnthropicMessages.format_messages([replayed])

    assert Enum.find(replayed_content, &(&1["type"] == "thinking")) == %{
             "type" => "thinking",
             "thinking" => "Need tools",
             "signature" => "signed-thinking"
           }
  end

  test "built agents fall back to stream_response when typed streaming is unsupported" do
    assert {:ok, %Built{} = agent} =
             Agent.build(
               name: "runtime_typed_stream_fallback_agent",
               model: %UnsupportedTypedStreamingModel{},
               tools: []
             )

    assert {:ok, stream} =
             Agent.stream_events(
               agent,
               %{messages: [Message.user("hello")]},
               stream_mode: :events,
               model_opts: [stream: true]
             )

    assert Enum.any?(
             stream,
             &match?(
               %Envelope{
                 event: %Events.GraphUpdate{
                   update: %{"model" => %{messages: [%Message{content: "stream response"}]}}
                 }
               },
               &1
             )
           )
  end

  test "runtime builder preserves explicit names" do
    assert {:ok, %Built{} = agent} =
             Agent.build(model: %ToolCallingModel{}, name: "custom_runtime_agent")

    assert agent.spec.name == "custom_runtime_agent"
  end

  test "runtime builder uses middleware for dynamic models and prompts" do
    parent = self()
    store = %{users: %{"user-1" => "Alice"}}

    prompt = fn _state, runtime ->
      "User name is #{runtime.store.users[runtime.context.user_id]}"
    end

    assert {:ok, %Built{} = agent} =
             Agent.build(
               name: "dynamic_runtime_agent",
               model: %RecordingContextModel{parent: parent},
               tools: [],
               middleware: [
                 %DynamicModelMiddleware{parent: parent},
                 DynamicPrompt.new(prompt: prompt)
               ],
               store: store,
               context_schema: %{
                 user_id: %{type: :string, required: true},
                 parent: %{type: :any, required: true}
               }
             )

    assert {:ok, %{messages: [%Message{role: :user}, %Message{content: "ok"}]}} =
             Agent.invoke(agent, %{messages: [Message.user("hi")], custom_field: "kept"},
               context: %{user_id: "user-1", parent: parent}
             )

    assert_receive {:dynamic_model_state, [%Message{content: "hi"}], "user-1"}

    assert_receive {:runtime_builder_model_call,
                    [
                      %Message{role: :system, content: "User name is Alice"},
                      %Message{role: :user}
                    ], opts}

    assert opts[:context].user_id == "user-1"
  end

  test "requires a model option" do
    assert {:error, %{type: :invalid_agent, details: %{option: :model}}} = Agent.build(tools: [])
  end

  defmodule StorageProbe do
    use BeamWeaver.Agent.Middleware

    defstruct [:parent]

    @impl true
    def before_model(%__MODULE__{parent: parent}, _state, runtime) do
      send(parent, {:storage_probe, runtime.store, runtime.cache})
      nil
    end
  end

  test "a built agent runs with the checkpointer, store and cache of each call" do
    {:ok, agent} =
      Agent.build(
        model: "fake:chat",
        model_opts: [responses: ["Order A-1001 shipped on Monday.", "You're welcome!"]],
        middleware: [%StorageProbe{parent: self()}]
      )

    saver = BeamWeaver.Checkpoint.ETS.new()
    store = BeamWeaver.Memory.ETS.new()
    cache = BeamWeaver.Cache.ETS.new()

    opts = [
      checkpointer: saver,
      store: store,
      cache: cache,
      config: %{"configurable" => %{"thread_id" => "built-thread"}}
    ]

    assert {:ok, _first} = Agent.invoke(agent, %{messages: ["Where is my order?"]}, opts)
    assert {:ok, second} = Agent.invoke(agent, %{messages: ["Thanks!"]}, opts)

    assert Enum.map(second.messages, &Message.text/1) == [
             "Where is my order?",
             "Order A-1001 shipped on Monday.",
             "Thanks!",
             "You're welcome!"
           ]

    assert {:ok, snapshot} = Agent.get_state(agent, opts)
    assert length(snapshot.values.messages) == 4
    assert_received {:storage_probe, ^store, ^cache}
  end

  test "build/1 returns an error naming the options it doesn't know" do
    assert {:error, %BeamWeaver.Core.Error{type: :invalid_agent, details: %{options: [:response_schema, :debug]}}} =
             Agent.build(model: "fake:chat", response_schema: %{"title" => "Triage"}, debug: true)

    assert {:error, %BeamWeaver.Core.Error{type: :invalid_agent, details: %{options: ["respons_format"]}}} =
             Agent.build(%{"model" => "fake:chat", "respons_format" => nil})
  end

  test "build/1 returns an error for an invalid tool or middleware entry" do
    tool =
      Tool.from_function!(
        name: "adder",
        description: "Add two numbers",
        input_schema: %{"required" => ["a", "b"]},
        handler: fn %{"a" => a, "b" => b}, _opts -> a + b end
      )

    assert {:error, %BeamWeaver.Core.Error{type: :invalid_tool, details: %{options: [:retries]}}} =
             Agent.build(model: "fake:chat", tools: [{tool, retries: 3}])

    assert {:error, %BeamWeaver.Core.Error{type: :invalid_middleware}} =
             Agent.build(model: "fake:chat", middleware: [String])
  end

  test "build/1 returns an error for a tool that isn't one and a response format without a schema" do
    # A tool name raised FunctionClauseError; a module without a schema asked
    # the model for an empty object.
    assert {:error, %BeamWeaver.Core.Error{type: :invalid_tool, details: %{tool: ~s("lookup_order")}}} =
             Agent.build(model: "fake:chat", tools: ["lookup_order"])

    assert {:error,
            %BeamWeaver.Core.Error{type: :invalid_agent, message: message, details: %{response_format: "String"}}} =
             Agent.build(model: "fake:chat", response_format: String)

    assert message =~ "response_format String declares no schema"

    assert {:error, %BeamWeaver.Core.Error{type: :invalid_agent, details: %{response_format: ~s("triage")}}} =
             Agent.build(model: "fake:chat", response_format: "triage")
  end

  test "a model that is neither a model string nor a model struct is an :invalid_agent_model error" do
    assert {:error, %BeamWeaver.Core.Error{type: :invalid_agent_model, details: %{model: "a tuple of 2 elements"}}} =
             Agent.build(model: {"fake:chat", []})

    assert {:error, %BeamWeaver.Core.Error{type: :invalid_agent_model}} =
             Agent.build(model: fn _state -> "fake:chat" end)
  end

  test "middleware or capability settings their constructors reject are errors, not exceptions" do
    alias BeamWeaver.Agent.Middleware

    for entry <- [
          Middleware.DynamicPrompt,
          {Middleware.CompactConversation, trigger: {:messages, 5}},
          {Middleware.Summarization, keep: {:fraction, 0.5}, api_key: "sk-proj-not-a-real-key"},
          {Middleware.OverflowRecovery, keep: {:messages, 8}}
        ] do
      assert {:error, %BeamWeaver.Core.Error{type: :invalid_middleware} = error} =
               Agent.build(model: "fake:chat", middleware: [entry])

      refute inspect(error) =~ "not-a-real-key"
    end

    assert {:error, %BeamWeaver.Core.Error{type: :invalid_middleware, message: message}} =
             Agent.build(model: "fake:chat", middleware: [Middleware.DynamicPrompt])

    assert message == "BeamWeaver.Agent.Middleware.DynamicPrompt: key :prompt not found"

    assert {:error, %BeamWeaver.Core.Error{type: :invalid_agent, message: "CompactConversation doesn't take" <> _}} =
             Agent.build(model: "fake:chat", compact_conversation: [trigger: {:messages, 5}])
  end

  test "errors about the model and its options don't show their values" do
    assert {:error, %BeamWeaver.Core.Error{type: :invalid_agent_model} = tuple_model} =
             Agent.build(model: {"openai:gpt-5.4", [api_key: "sk-proj-not-a-real-key"]})

    assert {:error,
            %BeamWeaver.Core.Error{type: :invalid_agent, details: %{model_opts: "a map with keys [:api_key]"}} =
              map_opts} =
             Agent.build(model: "fake:chat", model_opts: %{api_key: "sk-proj-not-a-real-key"})

    refute inspect(tuple_model) =~ "not-a-real-key"
    refute inspect(map_opts) =~ "not-a-real-key"
  end
end
