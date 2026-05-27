defmodule BeamWeaver.Agent.DSLBehaviorTest do
  use ExUnit.Case, async: true

  # Upstream references:
  # - langgraph/libs/prebuilt/tests/test_react_agent.py::test_model_with_tools
  # - langgraph/libs/prebuilt/tests/test_react_agent.py::test_react_agent_with_structured_response
  # - langgraph/libs/prebuilt/tests/test_react_agent.py::test_dynamic_model_with_context
  # - langgraph/libs/prebuilt/tests/test_react_agent.py::test_dynamic_model_with_prompt
  # - langchain/libs/langchain_v1/tests/unit_tests/agents/middleware/core/test_wrap_model_call.py
  # - langchain/libs/langchain_v1/tests/unit_tests/agents/middleware/core/test_wrap_tool_call.py
  # - langchain/libs/langchain_v1/tests/unit_tests/agents/middleware/core/test_framework.py
  # - langgraph/libs/prebuilt/tests/test_validation_node.py::test_validation_node

  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Agent.ModelResponse
  alias BeamWeaver.Agent.ToolCallRequest
  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool

  defmodule RecordingModel do
    @behaviour ChatModel

    defstruct [:parent, :label, :reply]

    @impl true
    def invoke(%__MODULE__{} = model, messages, opts) do
      if parent = parent(model.parent, opts) do
        send(
          parent,
          {:model_call, model.label, Enum.map(messages, &{&1.role, &1.content}), opts}
        )
      end

      {:ok, Message.assistant(model.reply || "done")}
    end

    defp parent(:context, opts), do: opts |> Keyword.get(:context, %{}) |> Map.get(:parent)
    defp parent(parent, _opts), do: parent
  end

  defmodule ToolRewriteModel do
    @behaviour ChatModel

    defstruct [:parent]

    @impl true
    def invoke(%__MODULE__{parent: parent}, messages, opts) do
      if parent,
        do: send(parent, {:tool_model_call, Enum.map(Keyword.get(opts, :tools, []), &Tool.name/1)})

      case Enum.find(messages, &(&1.role == :tool)) do
        %Message{} = tool_message ->
          {:ok, Message.assistant("final: #{tool_message.content}")}

        nil ->
          {:ok,
           Message.assistant("",
             tool_calls: [
               %{id: "call-echo", name: "echo", args: %{"value" => "raw"}}
             ]
           )}
      end
    end
  end

  defmodule ReturnDirectModel do
    @behaviour ChatModel

    defstruct [:parent]

    @impl true
    def invoke(%__MODULE__{parent: parent}, messages, _opts) do
      send(parent, {:return_direct_model_call, Enum.map(messages, & &1.role)})

      if Enum.any?(messages, &(&1.role == :tool)) do
        {:ok, Message.assistant("should not be called")}
      else
        {:ok,
         Message.assistant("",
           tool_calls: [
             %{id: "call-finish", name: "finish", args: %{"answer" => "done"}}
           ]
         )}
      end
    end
  end

  defmodule StepLimitModel do
    @behaviour ChatModel

    defstruct [:parent]

    @impl true
    def invoke(%__MODULE__{parent: parent}, messages, _opts) do
      send(parent, {:step_limit_model_call, Enum.map(messages, & &1.role)})

      {:ok,
       Message.assistant("",
         id: "ai-step-limit",
         tool_calls: [
           %{id: "call-step-limit", name: "echo", args: %{"value" => "too late"}}
         ]
       )}
    end
  end

  defmodule ToolValidationRetryModel do
    @behaviour ChatModel

    defstruct [:parent]

    @impl true
    def invoke(%__MODULE__{parent: parent}, messages, opts) do
      parent = parent(parent, opts)
      if parent, do: send(parent, {:validation_model_call, Enum.map(messages, & &1.role)})

      cond do
        Enum.any?(messages, &match?(%Message{role: :tool, content: "selected 37"}, &1)) ->
          {:ok, Message.assistant("final: selected 37")}

        Enum.any?(messages, &validation_error?/1) ->
          {:ok,
           Message.assistant("",
             tool_calls: [
               %{id: "call-corrected", name: "select_number", args: %{"value" => 37}}
             ]
           )}

        true ->
          {:ok,
           Message.assistant("",
             tool_calls: [
               %{id: "call-invalid", name: "select_number", args: %{"value" => "bad"}}
             ]
           )}
      end
    end

    defp validation_error?(%Message{role: :tool, metadata: metadata}) do
      Map.get(metadata || %{}, :is_error) == true
    end

    defp validation_error?(_message), do: false
    defp parent(:context, opts), do: opts |> Keyword.get(:context, %{}) |> Map.get(:parent)
    defp parent(parent, _opts), do: parent
  end

  defmodule ToolValidationValidModel do
    @behaviour ChatModel

    defstruct [:parent]

    @impl true
    def invoke(%__MODULE__{parent: parent}, messages, opts) do
      parent = parent(parent, opts)
      if parent, do: send(parent, {:valid_validation_model_call, Enum.map(messages, & &1.role)})

      case Enum.find(messages, &match?(%Message{role: :tool}, &1)) do
        %Message{content: content} ->
          {:ok, Message.assistant("final: #{content}")}

        nil ->
          {:ok,
           Message.assistant("",
             tool_calls: [
               %{id: "call-valid", name: "select_number", args: %{"value" => 41}}
             ]
           )}
      end
    end

    defp parent(:context, opts), do: opts |> Keyword.get(:context, %{}) |> Map.get(:parent)
    defp parent(parent, _opts), do: parent
  end

  defmodule StructuredModel do
    @behaviour ChatModel

    defstruct [:parent]

    @impl true
    def invoke(%__MODULE__{parent: parent}, _messages, opts) do
      if parent,
        do: send(parent, {:structured_tools, Enum.map(Keyword.get(opts, :tools, []), &Tool.name/1)})

      {:ok,
       Message.assistant("",
         tool_calls: [
           %{id: "call-answer", name: "answer", args: %{"value" => "ok"}}
         ]
       )}
    end
  end

  defmodule MixedStructuredToolModel do
    @behaviour ChatModel

    defstruct [:parent]

    @impl true
    def invoke(%__MODULE__{parent: parent}, messages, opts) do
      if parent,
        do:
          send(
            parent,
            {:mixed_structured_model_call, Enum.map(messages, & &1.role),
             Enum.map(Keyword.get(opts, :tools, []), &Tool.name/1)}
          )

      if Enum.any?(messages, &match?(%Message{role: :tool, name: "regular_tool"}, &1)) do
        {:ok, Message.assistant("should not be called after mixed structured response")}
      else
        {:ok,
         Message.assistant("",
           tool_calls: [
             %{id: "call-answer", name: "answer", args: %{"value" => "ok"}},
             %{id: "call-regular", name: "regular_tool", args: %{"query" => "test query"}}
           ]
         )}
      end
    end
  end

  defmodule ProviderStructuredModel do
    @behaviour ChatModel

    defstruct [:parent, supports_structured_output: true]

    @impl true
    def invoke(%__MODULE__{parent: parent}, _messages, opts) do
      if parent,
        do: send(parent, {:provider_response_format, Keyword.get(opts, :response_format)})

      {:ok, Message.assistant("", metadata: %{parsed: %{"value" => "native"}})}
    end
  end

  defmodule OrderMiddleware do
    @behaviour BeamWeaver.Agent.Middleware

    def name(_middleware), do: :order_middleware

    def before_model(_state, runtime) do
      send(runtime.context.parent, :before_model)
      nil
    end

    def wrap_model_call(request, handler) do
      send(request.runtime.context.parent, :wrap_model_before)
      result = handler.(request)
      send(request.runtime.context.parent, :wrap_model_after)
      result
    end

    def after_model(_state, runtime) do
      send(runtime.context.parent, :after_model)
      nil
    end
  end

  defmodule ShortCircuitModelMiddleware do
    @behaviour BeamWeaver.Agent.Middleware

    def name(_middleware), do: :short_circuit_model_middleware

    def wrap_model_call(request, _handler) do
      send(request.runtime.context.parent, :short_circuit_model)
      %ModelResponse{messages: [Message.assistant("cached")]}
    end
  end

  defmodule SwitchModelMiddleware do
    @behaviour BeamWeaver.Agent.Middleware

    def name(_middleware), do: :switch_model_middleware

    def wrap_model_call(request, handler) do
      replacement = %RecordingModel{
        parent: request.runtime.context.parent,
        label: :switched,
        reply: "switched"
      }

      request
      |> ModelRequest.override(model: replacement)
      |> handler.()
    end
  end

  defmodule UppercaseResponseMiddleware do
    @behaviour BeamWeaver.Agent.Middleware

    def name(_middleware), do: :uppercase_response_middleware

    def wrap_model_call(request, handler) do
      case handler.(request) do
        {:ok, %ModelResponse{} = response} ->
          messages =
            Enum.map(response.messages, fn
              %Message{role: :assistant, content: content} = message when is_binary(content) ->
                %{message | content: String.upcase(content)}

              message ->
                message
            end)

          {:ok, %{response | messages: messages}}

        other ->
          other
      end
    end
  end

  defmodule RewriteToolMiddleware do
    @behaviour BeamWeaver.Agent.Middleware

    def name(_middleware), do: :rewrite_tool_middleware

    def wrap_tool_call(request, handler) do
      rewritten_call = Map.put(request.tool_call, :args, %{"value" => "rewritten"})
      handler.(ToolCallRequest.override(request, tool_call: rewritten_call))
    end
  end

  defmodule ToolNodeSpyMiddleware do
    @behaviour BeamWeaver.Agent.Middleware

    def name(_middleware), do: :tool_node_spy_middleware

    def wrap_tool_call(request, handler) do
      send(
        request.runtime.context.parent,
        {:tool_node_call, request.tool_call.name, request.tool_call.args}
      )

      handler.(request)
    end
  end

  defmodule JumpMiddleware do
    @behaviour BeamWeaver.Agent.Middleware

    def name(_middleware), do: :jump_middleware

    def state_schema(_middleware) do
      %{
        messages: BeamWeaver.Graph.Messages.channel(),
        remaining_steps: BeamWeaver.Graph.managed(BeamWeaver.Graph.Managed.RemainingSteps),
        jump_to: BeamWeaver.Graph.private_channel(BeamWeaver.Graph.Channels.EphemeralValue)
      }
    end

    def before_model(_state, _runtime) do
      {:jump, :end, %{messages: [Message.assistant("skipped")]}}
    end
  end

  defmodule ContextSchemaMiddleware do
    @behaviour BeamWeaver.Agent.Middleware

    def name(_middleware), do: :context_schema_middleware

    def context_schema(_middleware) do
      %{account_id: BeamWeaver.Agent.Schema.field(:account_id, :string, required: true)}
    end
  end

  defmodule DynamicContextMiddleware do
    @behaviour BeamWeaver.Agent.Middleware

    def name(_middleware), do: :dynamic_context_middleware

    def wrap_model_call(request, handler) do
      tier = request.runtime.context.tier

      request
      |> ModelRequest.override(
        model: %RecordingModel{
          parent: request.runtime.context.parent,
          label: tier,
          reply: "tier=#{tier}"
        },
        system_prompt: "tier prompt #{tier}"
      )
      |> handler.()
    end
  end

  defmodule DynamicContextAgent do
    use BeamWeaver.Agent

    context_schema do
      field(:tier, :atom, required: true)
    end

    model(%RecordingModel{label: :default, reply: "default"})
    middleware([DynamicContextMiddleware])
  end

  defmodule MiddlewareOrderAgent do
    use BeamWeaver.Agent

    model(__MODULE__.model())
    middleware([OrderMiddleware])

    def model, do: %RecordingModel{parent: self(), label: :order, reply: "done"}
  end

  defmodule ShortCircuitModelAgent do
    use BeamWeaver.Agent

    context_schema do
      field(:parent, :any, required: true)
    end

    model(%RecordingModel{parent: :context, label: :short_circuit, reply: "miss"})
    middleware([ShortCircuitModelMiddleware])
  end

  defmodule ModelWrapperTransformAgent do
    use BeamWeaver.Agent

    context_schema do
      field(:parent, :any, required: true)
    end

    model(%RecordingModel{parent: :context, label: :original, reply: "original"})
    middleware([SwitchModelMiddleware, UppercaseResponseMiddleware])
  end

  defmodule ToolRewriteAgent do
    use BeamWeaver.Agent

    model(__MODULE__.model())
    tools(__MODULE__.tools())
    middleware([RewriteToolMiddleware])

    def model, do: %ToolRewriteModel{parent: self()}

    def tools do
      [
        Tool.from_function!(
          name: "echo",
          description: "Echo a value",
          input_schema: %{
            "required" => ["value"],
            "properties" => %{"value" => %{"type" => "string"}}
          },
          handler: fn %{"value" => value}, _opts -> value end
        )
      ]
    end
  end

  defmodule ReturnDirectAgent do
    use BeamWeaver.Agent

    model(__MODULE__.model())
    tools(__MODULE__.tools())

    def model, do: %ReturnDirectModel{parent: self()}

    def tools do
      [
        Tool.from_function!(
          name: "finish",
          description: "Finish immediately",
          input_schema: %{
            "required" => ["answer"],
            "properties" => %{"answer" => %{"type" => "string"}}
          },
          return_direct: true,
          handler: fn %{"answer" => answer}, _opts -> answer end
        )
      ]
    end
  end

  defmodule StepLimitAgent do
    use BeamWeaver.Agent

    model(__MODULE__.model())
    tools(__MODULE__.tools())

    def model, do: %StepLimitModel{parent: self()}

    def tools do
      [
        Tool.from_function!(
          name: "echo",
          description: "Echo a value",
          input_schema: %{
            "required" => ["value"],
            "properties" => %{"value" => %{"type" => "string"}}
          },
          handler: fn %{"value" => value}, _opts ->
            send(self(), {:unexpected_step_limit_tool, value})
            value
          end
        )
      ]
    end
  end

  defmodule ToolValidationAgent do
    use BeamWeaver.Agent

    context_schema do
      field(:parent, :any, required: true)
    end

    model(%ToolValidationRetryModel{parent: :context})
    tools(__MODULE__.tools())
    middleware([ToolNodeSpyMiddleware])
    validate_tools(true)

    def tools do
      [
        Tool.from_function!(
          name: "select_number",
          description: "Select a number",
          input_schema: %{
            "required" => ["value"],
            "properties" => %{"value" => %{"type" => "integer"}}
          },
          injected: %{"context" => :context},
          handler: fn %{"value" => value, "context" => context}, _opts ->
            send(context.parent, {:validated_tool_executed, value})
            "selected #{value}"
          end
        )
      ]
    end
  end

  defmodule ToolValidationValidAgent do
    use BeamWeaver.Agent

    context_schema do
      field(:parent, :any, required: true)
    end

    model(%ToolValidationValidModel{parent: :context})
    tools(__MODULE__.tools())
    validate_tools(true)

    def tools do
      [
        Tool.from_function!(
          name: "select_number",
          description: "Select a number",
          input_schema: %{
            "required" => ["value"],
            "properties" => %{"value" => %{"type" => "integer"}}
          },
          handler: fn %{"value" => value}, _opts -> "selected #{value}" end
        )
      ]
    end
  end

  defmodule StructuredOutputAgent do
    use BeamWeaver.Agent

    @schema %{
      "title" => "answer",
      "type" => "object",
      "required" => ["value"],
      "properties" => %{"value" => %{"type" => "string"}}
    }

    model(__MODULE__.model())
    response_format(BeamWeaver.Agent.StructuredOutput.tool(@schema))

    def model, do: %StructuredModel{parent: self()}
  end

  defmodule MixedStructuredToolAgent do
    use BeamWeaver.Agent

    @schema %{
      "title" => "answer",
      "type" => "object",
      "required" => ["value"],
      "properties" => %{"value" => %{"type" => "string"}}
    }

    model(__MODULE__.model())
    tools(__MODULE__.tools())
    response_format(BeamWeaver.Agent.StructuredOutput.tool(@schema))

    def model, do: %MixedStructuredToolModel{parent: self()}

    def tools do
      [
        Tool.from_function!(
          name: "regular_tool",
          description: "A regular tool.",
          input_schema: %{
            "required" => ["query"],
            "properties" => %{"query" => %{"type" => "string"}}
          },
          handler: fn %{"query" => query}, _opts -> "regular result for #{query}" end
        )
      ]
    end
  end

  defmodule ProviderStructuredOutputAgent do
    use BeamWeaver.Agent

    @schema %{
      "title" => "provider_answer",
      "type" => "object",
      "required" => ["value"],
      "properties" => %{"value" => %{"type" => "string"}}
    }

    model(__MODULE__.model())
    response_format(@schema)

    def model, do: %ProviderStructuredModel{parent: self()}
  end

  defmodule JumpAgent do
    use BeamWeaver.Agent

    model(__MODULE__.model())
    middleware([JumpMiddleware])

    def model, do: %RecordingModel{parent: self(), label: :jump, reply: "should not run"}
  end

  defmodule MiddlewareContextAgent do
    use BeamWeaver.Agent

    model(__MODULE__.model())
    middleware([ContextSchemaMiddleware])

    def model, do: %RecordingModel{parent: self(), label: :middleware_context, reply: "done"}
  end

  defmodule NamedAgent do
    use BeamWeaver.Agent

    name(:named_agent)
    model(__MODULE__.model())
    tools(__MODULE__.tools())

    def model, do: %ToolRewriteModel{parent: self()}
    def tools, do: ToolRewriteAgent.tools()
  end

  test "dynamic model selection and system prompt receive runtime context" do
    assert {:ok, %{messages: [_user, assistant]}} =
             DynamicContextAgent.invoke(%{messages: [Message.user("hello")]},
               context: %{tier: :pro, parent: self()}
             )

    assert assistant.content == "tier=pro"

    assert_receive {:model_call, :pro, [system: "tier prompt pro", user: "hello"], opts}
    assert opts[:context].tier == :pro
  end

  test "declared context schema rejects missing required runtime context" do
    assert {:error, %Error{type: :invalid_context}} =
             DynamicContextAgent.invoke(%{messages: [Message.user("hello")]},
               context: %{parent: self()}
             )
  end

  test "middleware-declared context schema participates in runtime validation" do
    assert {:error, %Error{type: :invalid_context}} =
             MiddlewareContextAgent.invoke(%{messages: [Message.user("hello")]},
               context: %{parent: self()}
             )
  end

  test "declared agent name is set on assistant messages across model iterations" do
    # Upstream reference:
    # langchain/libs/langchain_v1/tests/unit_tests/agents/test_agent_name.py
    assert {:ok, %{messages: messages}} =
             NamedAgent.invoke(%{messages: [Message.user("echo")]})

    assistant_messages = Enum.filter(messages, &match?(%Message{role: :assistant}, &1))
    assert length(assistant_messages) == 2
    assert Enum.all?(assistant_messages, &(&1.name == "named_agent"))
  end

  test "model middleware runs in LangChain wrapper order around every model call" do
    assert {:ok, %{messages: [_user, %Message{content: "done"}]}} =
             MiddlewareOrderAgent.invoke(%{messages: [Message.user("hi")]},
               context: %{parent: self()}
             )

    assert_receive :before_model
    assert_receive :wrap_model_before
    assert_receive {:model_call, :order, _messages, _opts}
    assert_receive :wrap_model_after
    assert_receive :after_model
  end

  test "model middleware can short-circuit without calling the model" do
    assert {:ok, %{messages: [_user, %Message{content: "cached"}]}} =
             ShortCircuitModelAgent.invoke(%{messages: [Message.user("hi")]},
               context: %{parent: self()}
             )

    assert_receive :short_circuit_model
    refute_received {:model_call, :short_circuit, _messages, _opts}
  end

  test "model middleware can modify request model and rewrite the response" do
    assert {:ok, %{messages: [_user, %Message{content: "SWITCHED"}]}} =
             ModelWrapperTransformAgent.invoke(%{messages: [Message.user("hi")]},
               context: %{parent: self()}
             )

    assert_receive {:model_call, :switched, _messages, _opts}
    refute_received {:model_call, :original, _messages, _opts}
  end

  test "tool middleware can rewrite a tool call before execution" do
    assert {:ok, %{messages: messages}} =
             ToolRewriteAgent.invoke(%{messages: [Message.user("echo")]})

    assert %Message{role: :tool, content: "rewritten"} =
             Enum.find(messages, &(&1.role == :tool))

    assert %Message{role: :assistant, content: "final: rewritten"} = List.last(messages)
    assert_receive {:tool_model_call, ["echo"]}
  end

  test "return_direct tools stop the generated agent loop after the tool result" do
    assert {:ok, %{messages: messages}} =
             ReturnDirectAgent.invoke(%{messages: [Message.user("finish now")]})

    assert [
             %Message{role: :user, content: "finish now"},
             %Message{role: :assistant, tool_calls: [%{name: "finish"}]},
             %Message{
               role: :tool,
               content: "done",
               tool_call_id: "call-finish",
               metadata: %{return_direct: true}
             }
           ] = messages

    assert_receive {:return_direct_model_call, [:user]}
    refute_receive {:return_direct_model_call, [:user, :assistant, :tool]}, 50
  end

  test "return_direct tools still respect the final-attempt step budget" do
    # Upstream reference:
    # langgraph/prebuilt/chat_agent_executor.py::_are_more_steps_needed
    # - a final model attempt with tool calls returns the apology instead of
    #   executing tools when no safe tool step remains, even for return_direct tools.
    assert {:ok, %{messages: messages}} =
             ReturnDirectAgent.invoke(%{messages: [Message.user("finish now")]},
               recursion_limit: 1
             )

    assert [
             %Message{role: :user, content: "finish now"},
             %Message{
               role: :assistant,
               content: "Sorry, need more steps to process this request.",
               tool_calls: []
             }
           ] = messages

    assert_receive {:return_direct_model_call, [:user]}
    refute Enum.any?(messages, &match?(%Message{role: :tool}, &1))
  end

  test "return_direct tools execute when exactly one tool step remains" do
    # Upstream reference:
    # langgraph/prebuilt/tests/test_react_agent.py::test_return_direct
    # - enough budget for a model step and a direct tool step should finish on
    #   the tool result without another model call.
    assert {:ok, %{messages: messages}} =
             ReturnDirectAgent.invoke(%{messages: [Message.user("finish now")]},
               recursion_limit: 2
             )

    assert [
             %Message{role: :user},
             %Message{role: :assistant, tool_calls: [%{name: "finish"}]},
             %Message{role: :tool, content: "done", metadata: %{return_direct: true}}
           ] = messages

    assert_receive {:return_direct_model_call, [:user]}
    refute_receive {:return_direct_model_call, [:user, :assistant, :tool]}, 50
  end

  test "remaining_steps returns an apology instead of tool calls when no step budget remains" do
    # Upstream: langgraph/prebuilt/chat_agent_executor.py::_are_more_steps_needed
    assert {:ok, %{messages: messages}} =
             StepLimitAgent.invoke(%{messages: [Message.user("echo")]}, recursion_limit: 1)

    assert [
             %Message{role: :user, content: "echo"},
             %Message{
               role: :assistant,
               id: "ai-step-limit",
               content: "Sorry, need more steps to process this request.",
               tool_calls: []
             }
           ] = messages

    assert_receive {:step_limit_model_call, [:user]}
    refute Enum.any?(messages, &match?(%Message{role: :tool}, &1))
  end

  test "validate_tools reprompts on invalid generated-loop tool calls before execution" do
    assert {:ok, %{messages: messages}} =
             ToolValidationAgent.invoke(%{messages: [Message.user("select a number")]},
               context: %{parent: self()}
             )

    assert Enum.any?(messages, fn
             %Message{role: :tool, tool_call_id: "call-invalid", metadata: metadata} ->
               metadata.is_error == true

             _message ->
               false
           end)

    assert Enum.any?(messages, fn
             %Message{role: :tool, tool_call_id: "call-corrected", content: "selected 37"} ->
               true

             _message ->
               false
           end)

    assert %Message{role: :assistant, content: "final: selected 37"} = List.last(messages)

    assert_receive {:tool_node_call, "select_number", %{"value" => 37}}
    refute_receive {:tool_node_call, "select_number", %{"value" => "bad"}}, 50
    assert_receive {:validated_tool_executed, 37}
  end

  test "validate_tools does not add duplicate success tool messages before ToolNode" do
    assert {:ok, %{messages: messages}} =
             ToolValidationValidAgent.invoke(%{messages: [Message.user("select a number")]},
               context: %{parent: self()}
             )

    tool_messages = Enum.filter(messages, &match?(%Message{role: :tool}, &1))

    assert [
             %Message{
               role: :tool,
               tool_call_id: "call-valid",
               name: "select_number",
               content: "selected 41"
             }
           ] = tool_messages

    assert %Message{role: :assistant, content: "final: selected 41"} = List.last(messages)
  end

  test "structured output tool strategy stores structured_response and finishes the loop" do
    assert {:ok, %{structured_response: %{"value" => "ok"}, messages: messages}} =
             StructuredOutputAgent.invoke(%{messages: [Message.user("answer")]})

    assert Enum.any?(messages, &match?(%Message{role: :tool, name: "answer"}, &1))
    assert_receive {:structured_tools, tool_names}
    assert "answer" in tool_names
  end

  test "structured output and regular tool calls execute regular tools before ending" do
    assert {:ok, %{structured_response: %{"value" => "ok"}, messages: messages}} =
             MixedStructuredToolAgent.invoke(%{messages: [Message.user("answer and search")]})

    assert Enum.any?(messages, &match?(%Message{role: :tool, name: "answer"}, &1))

    assert Enum.any?(
             messages,
             &match?(
               %Message{
                 role: :tool,
                 name: "regular_tool",
                 content: "regular result for test query"
               },
               &1
             )
           )

    assert_receive {:mixed_structured_model_call, [:user], tool_names}
    assert "answer" in tool_names
    assert "regular_tool" in tool_names
    refute_receive {:mixed_structured_model_call, [:user, :assistant, :tool, :tool], _tools}, 50
  end

  test "auto structured output uses provider strategy when the model supports it" do
    assert {:ok, %{structured_response: %{"value" => "native"}, messages: messages}} =
             ProviderStructuredOutputAgent.invoke(%{messages: [Message.user("answer")]})

    assert [%Message{role: :user}, %Message{role: :assistant}] = messages

    assert_receive {:provider_response_format, %{name: "provider_answer", schema: schema, validator: validator}}

    assert schema["required"] == ["value"]
    assert is_function(validator, 1)
  end

  test "middleware jump routes to end and private jump channel is not exposed" do
    assert {:ok, %{messages: messages} = state} =
             JumpAgent.invoke(%{messages: [Message.user("skip")]})

    assert Enum.map(messages, & &1.content) == ["skip", "skipped"]
    refute Map.has_key?(state, :jump_to)
    refute_receive {:model_call, :jump, _messages, _opts}
  end
end
