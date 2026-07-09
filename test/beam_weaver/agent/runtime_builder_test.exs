defmodule BeamWeaver.Agent.RuntimeBuilderTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent
  alias BeamWeaver.Agent.Built
  alias BeamWeaver.Agent.Middleware.DynamicPrompt
  alias BeamWeaver.Agent.ModelRequest
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

  defmodule DynamicModelMiddleware do
    @behaviour BeamWeaver.Agent.Middleware

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

    assert Enum.any?(events, &match?(%Envelope{event: %Events.Done{}}, &1))
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
end
