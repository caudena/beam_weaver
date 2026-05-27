defmodule BeamWeaver.Agent.PrebuiltTailTest do
  use ExUnit.Case, async: true

  # Upstream references:
  # - langchain/libs/langchain_v1/tests/unit_tests/agents/test_return_direct_graph.py
  # - langchain/libs/langchain_v1/tests/unit_tests/agents/test_return_direct_spec.py
  # - langchain/libs/langchain_v1/tests/unit_tests/agents/test_fetch_last_ai_and_tool_messages.py
  # - langchain/libs/langchain_v1/tests/unit_tests/agents/test_create_agent_tool_validation.py
  # - langchain/libs/langchain_v1/tests/unit_tests/agents/test_response_format.py
  # - langgraph/libs/prebuilt/tests/test_react_agent.py::test_return_direct
  # - langgraph/libs/prebuilt/tests/test_react_agent.py::test_tool_node_stream_writer

  alias BeamWeaver.Agent.StructuredOutput
  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Core.ToolRuntime
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events

  defmodule MixedReturnDirectModel do
    @behaviour ChatModel

    defstruct [:parent]

    @impl true
    def invoke(%__MODULE__{parent: parent}, messages, opts) do
      parent = parent(parent, opts)
      send(parent, {:mixed_return_direct_model_call, Enum.map(messages, & &1.role)})

      if Enum.any?(messages, &match?(%Message{role: :tool}, &1)) do
        {:ok, Message.assistant("should not be called after return_direct")}
      else
        {:ok,
         Message.assistant("",
           tool_calls: [
             %{id: "call-finish", name: "finish", args: %{"answer" => "done"}},
             %{id: "call-log", name: "log", args: %{"value" => "recorded"}}
           ]
         )}
      end
    end

    defp parent(:context, opts), do: opts |> Keyword.get(:context, %{}) |> Map.get(:parent)
    defp parent(parent, _opts), do: parent
  end

  defmodule MixedReturnDirectAgent do
    use BeamWeaver.Agent

    context_schema do
      field(:parent, :any, required: true)
    end

    model(%MixedReturnDirectModel{parent: :context})
    tools(__MODULE__.tools())

    def tools do
      [
        Tool.from_function!(
          name: "finish",
          description: "Return directly",
          input_schema: %{
            "required" => ["answer"],
            "properties" => %{"answer" => %{"type" => "string"}}
          },
          return_direct: true,
          handler: fn %{"answer" => answer}, _opts -> answer end
        ),
        Tool.from_function!(
          name: "log",
          description: "Normal side-effect tool",
          input_schema: %{
            "required" => ["value"],
            "properties" => %{"value" => %{"type" => "string"}}
          },
          injected: %{"context" => :context},
          handler: fn %{"value" => value, "context" => context}, _opts ->
            send(context.parent, {:normal_tool_executed, value})
            "logged:#{value}"
          end
        )
      ]
    end
  end

  defmodule SyntheticToolMessageMiddleware do
    @behaviour BeamWeaver.Agent.Middleware

    def name(_middleware), do: :synthetic_tool_message_middleware

    def after_model(state, runtime) do
      messages = Map.get(state, :messages, [])

      case List.last(messages) do
        %Message{role: :assistant, tool_calls: [%{id: id, name: name} | _]} ->
          send(runtime.context.parent, {:synthetic_tool_message, id})

          %{
            messages: [
              Message.tool("blocked by policy",
                tool_call_id: id,
                name: name,
                metadata: %{status: "error", synthetic: true}
              )
            ]
          }

        _other ->
          %{}
      end
    end
  end

  defmodule SatisfiedToolCallModel do
    @behaviour ChatModel

    defstruct [:parent]

    @impl true
    def invoke(%__MODULE__{parent: parent}, messages, opts) do
      parent = parent(parent, opts)
      send(parent, {:satisfied_model_call, Enum.map(messages, & &1.role)})

      if Enum.any?(messages, &match?(%Message{role: :tool, content: "blocked by policy"}, &1)) do
        {:ok, Message.assistant("final after synthetic tool result")}
      else
        {:ok,
         Message.assistant("",
           tool_calls: [
             %{id: "call-dangerous", name: "dangerous", args: %{"value" => "delete"}}
           ]
         )}
      end
    end

    defp parent(:context, opts), do: opts |> Keyword.get(:context, %{}) |> Map.get(:parent)
    defp parent(parent, _opts), do: parent
  end

  defmodule SyntheticSatisfiedAgent do
    use BeamWeaver.Agent

    context_schema do
      field(:parent, :any, required: true)
    end

    model(%SatisfiedToolCallModel{parent: :context})
    tools(__MODULE__.tools())
    middleware([SyntheticToolMessageMiddleware])

    def tools do
      [
        Tool.from_function!(
          name: "dangerous",
          description: "Should not run when already satisfied",
          input_schema: %{
            "required" => ["value"],
            "properties" => %{"value" => %{"type" => "string"}}
          },
          injected: %{"context" => :context},
          handler: fn %{"value" => value, "context" => context}, _opts ->
            send(context.parent, {:dangerous_tool_executed, value})
            "executed:#{value}"
          end
        )
      ]
    end
  end

  defmodule ValidationFilteringModel do
    @behaviour ChatModel

    defstruct [:parent]

    @impl true
    def invoke(%__MODULE__{parent: parent}, messages, opts) do
      parent = parent(parent, opts)
      send(parent, {:validation_filter_model_call, Enum.map(messages, & &1.role)})

      if Enum.any?(messages, &match?(%Message{role: :tool, metadata: %{is_error: true}}, &1)) do
        {:ok, Message.assistant("final after validation feedback")}
      else
        {:ok,
         Message.assistant("",
           tool_calls: [
             %{id: "call-search", name: "search_private", args: %{"query" => 12_345}}
           ]
         )}
      end
    end

    defp parent(:context, opts), do: opts |> Keyword.get(:context, %{}) |> Map.get(:parent)
    defp parent(parent, _opts), do: parent
  end

  defmodule ValidationFilteringAgent do
    use BeamWeaver.Agent

    context_schema do
      field(:parent, :any, required: true)
    end

    model(%ValidationFilteringModel{parent: :context})
    tools(__MODULE__.tools())
    validate_tools(true)

    def tools do
      [
        Tool.from_function!(
          name: "search_private",
          description: "Search with injected runtime data",
          input_schema: %{
            "type" => "object",
            "required" => ["query", "limit", "state", "store", "runtime"],
            "properties" => %{
              "query" => %{"type" => "string"},
              "limit" => %{"type" => "integer"},
              "state" => %{"type" => "object"},
              "store" => %{"type" => "object"},
              "runtime" => %{"type" => "object"}
            }
          },
          injected: %{"state" => :state, "store" => :store, "runtime" => :runtime},
          handler: fn input, _opts ->
            send(input.runtime.context.parent, {:search_private_executed, input})
            "never"
          end
        )
      ]
    end
  end

  defmodule UnionStructuredModel do
    @behaviour ChatModel

    defstruct [:parent]

    @impl true
    def invoke(%__MODULE__{parent: parent}, _messages, opts) do
      parent = parent(parent, opts)

      send(
        parent,
        {:union_structured_tools, Enum.map(Keyword.get(opts, :tools, []), &Tool.name/1)}
      )

      {:ok,
       Message.assistant("",
         tool_calls: [
           %{
             id: "call-weather",
             name: "weather_schema",
             args: %{"temperature" => 75.0, "condition" => "sunny"}
           }
         ]
       )}
    end

    defp parent(:context, opts), do: opts |> Keyword.get(:context, %{}) |> Map.get(:parent)
    defp parent(parent, _opts), do: parent
  end

  defmodule UnionStructuredAgent do
    use BeamWeaver.Agent

    @schema %{
      "oneOf" => [
        %{
          "title" => "weather_schema",
          "type" => "object",
          "required" => ["temperature", "condition"],
          "properties" => %{
            "temperature" => %{"type" => "number"},
            "condition" => %{"type" => "string"}
          }
        },
        %{
          "title" => "location_schema",
          "type" => "object",
          "required" => ["city", "country"],
          "properties" => %{
            "city" => %{"type" => "string"},
            "country" => %{"type" => "string"}
          }
        }
      ]
    }

    context_schema do
      field(:parent, :any, required: true)
    end

    model(%UnionStructuredModel{parent: :context})
    response_format(StructuredOutput.tool(@schema))
  end

  defmodule MultipleStructuredModel do
    @behaviour ChatModel

    defstruct [:parent]

    @impl true
    def invoke(%__MODULE__{parent: parent}, _messages, opts) do
      parent = parent(parent, opts)
      send(parent, :multiple_structured_model_call)

      {:ok,
       Message.assistant("",
         tool_calls: [
           %{
             id: "call-weather",
             name: "weather_schema",
             args: %{"temperature" => 75.0, "condition" => "sunny"}
           },
           %{
             id: "call-location",
             name: "location_schema",
             args: %{"city" => "New York", "country" => "USA"}
           }
         ]
       )}
    end

    defp parent(:context, opts), do: opts |> Keyword.get(:context, %{}) |> Map.get(:parent)
    defp parent(parent, _opts), do: parent
  end

  defmodule MultipleStructuredAgent do
    use BeamWeaver.Agent

    @schema %{
      "oneOf" => [
        %{
          "title" => "weather_schema",
          "type" => "object",
          "required" => ["temperature", "condition"],
          "properties" => %{
            "temperature" => %{"type" => "number"},
            "condition" => %{"type" => "string"}
          }
        },
        %{
          "title" => "location_schema",
          "type" => "object",
          "required" => ["city", "country"],
          "properties" => %{
            "city" => %{"type" => "string"},
            "country" => %{"type" => "string"}
          }
        }
      ]
    }

    context_schema do
      field(:parent, :any, required: true)
    end

    model(%MultipleStructuredModel{parent: :context})
    response_format(StructuredOutput.tool(@schema, handle_errors: false))
  end

  defmodule StreamedToolModel do
    @behaviour ChatModel

    defstruct [:parent]

    @impl true
    def invoke(%__MODULE__{parent: parent}, messages, opts) do
      parent = parent(parent, opts)
      send(parent, {:streamed_agent_model_call, Enum.map(messages, & &1.role)})

      if Enum.any?(messages, &match?(%Message{role: :tool}, &1)) do
        {:ok, Message.assistant("done")}
      else
        {:ok,
         Message.assistant("",
           tool_calls: [
             %{id: "call-stream", name: "stream_tool", args: %{"text" => "complete"}}
           ]
         )}
      end
    end

    defp parent(:context, opts), do: opts |> Keyword.get(:context, %{}) |> Map.get(:parent)
    defp parent(parent, _opts), do: parent
  end

  defmodule StreamedToolAgent do
    use BeamWeaver.Agent

    context_schema do
      field(:parent, :any, required: true)
    end

    model(%StreamedToolModel{parent: :context})
    tools(__MODULE__.tools())

    def tools do
      [
        Tool.from_function!(
          name: "stream_tool",
          description: "Tool that emits output deltas",
          input_schema: %{
            "required" => ["text"],
            "properties" => %{"text" => %{"type" => "string"}}
          },
          injected: %{"tool_runtime" => :tool_runtime},
          handler: fn %{"text" => text, "tool_runtime" => runtime}, _opts ->
            ToolRuntime.emit_output_delta(runtime, "partial")
            text
          end
        )
      ]
    end
  end

  test "mixed return_direct and normal tool calls execute once and stop after tool results" do
    assert {:ok, %{messages: messages}} =
             MixedReturnDirectAgent.invoke(%{messages: [Message.user("run both")]},
               context: %{parent: self()}
             )

    assert [
             %Message{role: :user},
             %Message{role: :assistant, tool_calls: [%{name: "finish"}, %{name: "log"}]},
             %Message{
               role: :tool,
               tool_call_id: "call-finish",
               content: "done",
               metadata: %{return_direct: true}
             },
             %Message{role: :tool, tool_call_id: "call-log", content: "logged:recorded"}
           ] = messages

    assert_receive {:normal_tool_executed, "recorded"}
    assert_receive {:mixed_return_direct_model_call, [:user]}
    refute_receive {:mixed_return_direct_model_call, [:user, :assistant, :tool, :tool]}, 50
  end

  test "synthetic satisfied tool messages route back to the model instead of executing tools" do
    assert {:ok, %{messages: messages}} =
             SyntheticSatisfiedAgent.invoke(%{messages: [Message.user("dangerous")]},
               context: %{parent: self()}
             )

    assert Enum.any?(
             messages,
             &match?(
               %Message{
                 role: :tool,
                 tool_call_id: "call-dangerous",
                 content: "blocked by policy",
                 metadata: %{synthetic: true}
               },
               &1
             )
           )

    assert %Message{role: :assistant, content: "final after synthetic tool result"} =
             List.last(messages)

    assert_receive {:synthetic_tool_message, "call-dangerous"}
    assert_receive {:satisfied_model_call, [:user]}
    assert_receive {:satisfied_model_call, [:user, :assistant, :tool]}
    refute_receive {:dangerous_tool_executed, _value}, 50
  end

  test "validate_tools feedback includes model-controllable args and excludes injected values" do
    assert {:ok, %{messages: messages}} =
             ValidationFilteringAgent.invoke(
               %{
                 messages: [Message.user("search")],
                 private_secret: "secret_session_token",
                 api_key: "sk-secret-key"
               },
               context: %{parent: self()}
             )

    error_message =
      Enum.find(messages, fn
        %Message{role: :tool, tool_call_id: "call-search", metadata: %{is_error: true}} -> true
        _message -> false
      end)

    assert %Message{content: content, metadata: %{status: "error"}} = error_message
    assert content =~ "query"
    assert content =~ "12345"
    assert content =~ "limit"
    refute content =~ "state"
    refute content =~ "store"
    refute content =~ "runtime"
    refute content =~ "private_secret"
    refute content =~ "secret_session_token"
    refute content =~ "sk-secret-key"

    assert %Message{role: :assistant, content: "final after validation feedback"} =
             List.last(messages)

    refute_receive {:search_private_executed, _input}, 50
  end

  test "tool strategy supports oneOf schemas by registering one structured tool per variant" do
    assert {:ok,
            %{
              structured_response: %{"temperature" => 75.0, "condition" => "sunny"},
              messages: messages
            }} =
             UnionStructuredAgent.invoke(%{messages: [Message.user("weather")]},
               context: %{parent: self()}
             )

    assert Enum.any?(messages, &match?(%Message{role: :tool, name: "weather_schema"}, &1))
    assert_receive {:union_structured_tools, tool_names}
    assert "weather_schema" in tool_names
    assert "location_schema" in tool_names
  end

  test "multiple structured-output tool calls fail when tool strategy retries are disabled" do
    assert {:error, %Error{type: :multiple_structured_outputs, message: message}} =
             MultipleStructuredAgent.invoke(%{messages: [Message.user("weather and location")]},
               context: %{parent: self()}
             )

    assert message =~ "multiple structured responses"
    assert_receive :multiple_structured_model_call
  end

  test "generated agent event streams include typed tool lifecycle events" do
    refute function_exported?(StreamedToolAgent, :stream, 2)

    assert {:ok, events} =
             StreamedToolAgent.stream_events(%{messages: [Message.user("stream")]},
               context: %{parent: self()}
             )

    assert Enum.any?(
             events,
             &match?(
               %Envelope{event: %Events.ToolStart{tool_call_id: "call-stream"}},
               &1
             )
           )

    assert Enum.any?(
             events,
             &match?(%Envelope{event: %Events.ToolDelta{tool_call_id: "call-stream"}}, &1)
           )

    assert Enum.any?(
             events,
             &match?(
               %Envelope{
                 event: %Events.ToolFinish{tool_call_id: "call-stream", output: "complete"}
               },
               &1
             )
           )

    assert_receive {:streamed_agent_model_call, [:user]}
    assert_receive {:streamed_agent_model_call, [:user, :assistant, :tool]}
  end

  test "generated agent event streams include task metadata for model and tool steps" do
    # Upstream references:
    # - langchain/libs/langchain_v1/tests/unit_tests/agents/test_agent_streaming.py
    # - langgraph/libs/prebuilt/tests/test_react_agent.py task/debug stream coverage
    assert {:ok, events} =
             StreamedToolAgent.stream_events(%{messages: [Message.user("stream")]},
               context: %{parent: self()}
             )

    task_events =
      for %Envelope{event: %Events.Task{} = task, graph: graph, namespace: ns} <- events do
        {task.kind, task.node, is_binary(task.task_id), graph, ns}
      end

    assert {:start, "model", true, _, []} =
             Enum.find(task_events, &match?({:start, "model", true, _, []}, &1))

    assert {:finish, "model", true, _, []} =
             Enum.find(task_events, &match?({:finish, "model", true, _, []}, &1))

    assert {:start, "tools", true, _, []} =
             Enum.find(task_events, &match?({:start, "tools", true, _, []}, &1))

    assert {:finish, "tools", true, _, []} =
             Enum.find(task_events, &match?({:finish, "tools", true, _, []}, &1))
  end
end
