defmodule BeamWeaver.Tracing.MiddlewareTraceTest do
  use ExUnit.Case, async: false

  alias BeamWeaver.Agent.Middleware
  alias BeamWeaver.Agent.Middleware.Filesystem
  alias BeamWeaver.Agent.Middleware.TodoList
  alias BeamWeaver.Agent.Middleware.ToolCallLimit
  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Agent.Nodes.Model, as: ModelNode
  alias BeamWeaver.Agent.StructuredOutput
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Graph.Nodes.ToolNode
  alias BeamWeaver.Models.FakeChatModel
  alias BeamWeaver.Tracing
  alias BeamWeaver.Tracing.Context
  alias BeamWeaver.Tracing.Store

  defmodule ToolWrapper do
    @behaviour BeamWeaver.Agent.Middleware

    def name(_middleware), do: :tool_wrapper

    def wrap_tool_call(request, handler) do
      handler.(request)
    end
  end

  defmodule ModelWrapper do
    @behaviour BeamWeaver.Agent.Middleware

    def name(_middleware), do: :model_wrapper

    def wrap_model_call(request, handler) do
      handler.(request)
    end
  end

  setup do
    Tracing.reset()
    Context.clear()

    on_exit(fn ->
      Tracing.reset()
      Context.clear()
    end)

    :ok
  end

  test "graph run traces include native trace fields and custom fields" do
    parent = self()

    graph =
      Graph.new(name: "native_trace_graph")
      |> Graph.add_node(:done, fn _state, runtime ->
        send(parent, {:runtime_config, runtime.config})
        %{ok: true}
      end)
      |> Graph.add_edge(Graph.start(), :done)
      |> Graph.add_edge(:done, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{ok: true}} =
             Compiled.invoke(graph, %{},
               trace: [
                 name: "customer_support_agent",
                 thread_id: "thread-1",
                 user_id: 42,
                 execution_mode: "support_chat",
                 environment: "test",
                 version: "version-1",
                 agent_name: "legacy_agent_name",
                 agent_type: "legacy_agent_type",
                 fields: %{
                   ticket_id: 123,
                   tenant_id: "acme",
                   agent_name: "legacy_agent_name",
                   api_key: "sk-nope",
                   nested: %{nope: true}
                 },
                 metadata: %{feature: "support_inbox"}
               ]
             )

    run = run_by_name!("customer_support_agent")

    assert run.kind == :graph
    assert run.metadata.thread_id == "thread-1"
    assert run.metadata.user_id == 42
    assert run.metadata.execution_mode == "support_chat"
    assert run.metadata.environment == "test"
    assert run.metadata.version == "version-1"
    assert run.metadata.feature == "support_inbox"
    assert run.metadata.custom_fields == %{"ticket_id" => "123", "tenant_id" => "acme"}
    refute Map.has_key?(run.metadata, :api_key)
    refute Map.has_key?(run.metadata, :agent_name)
    refute Map.has_key?(run.metadata, :agent_type)

    assert_received {:runtime_config, %{"configurable" => %{"thread_id" => "thread-1"}}}
  end

  test "wrap_model_call middleware traces as nested native chain spans" do
    node =
      ModelNode.new(%FakeChatModel{response: Message.assistant("ok")},
        middleware: [TodoList.new(), Filesystem.new()]
      )

    {:ok, parent} = Tracing.start_run("agent", kind: :graph, metadata: %{thread_id: "thread-1"})

    assert %{messages: [%Message{content: "ok"}]} =
             ModelNode.invoke(node, %{messages: [Message.user("hi")]}, %{})

    assert {:ok, _finished_parent} = Tracing.finish_run(parent)

    todo = run_by_name!("TodoListMiddleware.wrap_model_call")
    filesystem = run_by_name!("FilesystemMiddleware.wrap_model_call")
    model = run_by_kind_child!(:model, filesystem.id)

    assert todo.parent_id == parent.id
    assert filesystem.parent_id == todo.id
    assert model.parent_id == filesystem.id
    assert todo.metadata.middleware == "todo_list"
    assert filesystem.metadata.middleware == "deepagents_filesystem"
    assert model.metadata.thread_id == "thread-1"
    refute Map.has_key?(model.metadata, :middleware)
    refute Map.has_key?(model.metadata, :middleware_hook)
  end

  test "failed wrapper traces keep provider errors structured instead of writing fake outputs" do
    request = ModelRequest.new(messages: [Message.user("hi")])

    error =
      Error.new(:rate_limit_error, "Insufficient balance or no resource package.", %{
        status: 429,
        code: "1113",
        provider: "zai"
      })

    {:ok, parent} = Tracing.start_run("agent", kind: :graph, metadata: %{thread_id: "thread-1"})

    assert {:error, ^error} =
             Middleware.call_wrapper(ModelWrapper, :wrap_model_call, request, fn _request ->
               {:error, error}
             end)

    assert {:ok, _finished_parent} = Tracing.finish_run(parent)

    wrapper = run_by_name!("ModelWrapperMiddleware.wrap_model_call")

    assert wrapper.parent_id == parent.id
    assert wrapper.status == :error

    assert wrapper.error == %{
             type: :rate_limit_error,
             message: "Insufficient balance or no resource package.",
             details: %{status: 429, code: "1113", provider: "zai"}
           }

    assert wrapper.outputs == nil
    refute inspect(wrapper) =~ "%BeamWeaver.Core.Error{"
  end

  test "normal hooks emit short middleware spans" do
    {:ok, parent} = Tracing.start_run("agent", kind: :graph, metadata: %{thread_id: "thread-1"})

    assert is_nil(
             Middleware.call_hook(
               TodoList.new(),
               :after_model,
               %{messages: [Message.assistant("done", tool_calls: [])]},
               %{}
             )
           )

    assert {:ok, _finished_parent} = Tracing.finish_run(parent)

    hook = run_by_name!("TodoListMiddleware.after_model")

    assert hook.parent_id == parent.id
    assert hook.inputs.messages_count == 1
    assert hook.outputs == %{output: nil}
  end

  test "limit middleware hook spans include instance identity" do
    {:ok, parent} = Tracing.start_run("agent", kind: :graph, metadata: %{thread_id: "thread-1"})

    state = %{
      messages: [
        Message.assistant("",
          tool_calls: [
            %{id: "call-1", name: "search", args: %{}}
          ]
        )
      ]
    }

    assert %{thread_tool_call_count: %{"search" => 1}} =
             Middleware.call_hook(
               ToolCallLimit.new(tool_name: "search", thread_limit: 4),
               :after_model,
               state,
               %{}
             )

    assert %{thread_tool_call_count: %{"__all__" => 1}} =
             Middleware.call_hook(
               ToolCallLimit.new(thread_limit: 12),
               :after_model,
               state,
               %{}
             )

    assert {:ok, _finished_parent} = Tracing.finish_run(parent)

    scoped = run_by_name!("ToolCallLimitMiddleware[tool_call_limit:search].after_model")
    global = run_by_name!("ToolCallLimitMiddleware[tool_call_limit].after_model")

    assert scoped.parent_id == parent.id
    assert global.parent_id == parent.id
    assert scoped.metadata.middleware == "tool_call_limit:search"
    assert global.metadata.middleware == "tool_call_limit"
  end

  test "wrap_tool_call middleware traces around actual tool runs and preserves call metadata" do
    tool =
      Tool.from_function!(
        name: "trace_echo",
        description: "Echo input.",
        input_schema: %{
          "type" => "object",
          "properties" => %{"text" => %{"type" => "string"}},
          "required" => ["text"]
        },
        handler: fn input, _opts -> "echo #{input["text"]}" end
      )

    node = ToolNode.new([tool], wrap_tool_call: [ToolWrapper])

    {:ok, parent} = Tracing.start_run("agent", kind: :graph, metadata: %{thread_id: "thread-1"})

    assert [%Message{content: "echo hi"}] =
             ToolNode.invoke(
               node,
               [
                 %{
                   id: "provider-call-1",
                   call_id: "call-1",
                   provider_id: "provider-call-1",
                   name: "trace_echo",
                   args: %{"text" => "hi"}
                 }
               ],
               %{}
             )

    assert {:ok, _finished_parent} = Tracing.finish_run(parent)

    wrapper = run_by_name!("ToolWrapperMiddleware.wrap_tool_call")
    tool_run = run_by_name!("trace_echo")

    assert wrapper.parent_id == parent.id
    assert tool_run.parent_id == wrapper.id
    assert tool_run.metadata.tool_call_id == "call-1"
    assert tool_run.metadata.call_id == "call-1"
    assert tool_run.metadata.provider_id == "provider-call-1"
    assert tool_run.metadata.tool_call_index == 0
    assert tool_run.metadata.thread_id == "thread-1"
    refute Map.has_key?(tool_run.metadata, :middleware)
    refute Map.has_key?(tool_run.metadata, :middleware_hook)
    assert tool_run.outputs == %{output: "echo hi"}
  end

  test "structured output traces as a sequence parent with parsed output" do
    schema = %{
      "title" => "answer",
      "type" => "object",
      "properties" => %{"ok" => %{"type" => "boolean"}},
      "required" => ["ok"]
    }

    node =
      ModelNode.new(
        %FakeChatModel{
          structured_response: %{"ok" => true},
          profile: %{structured_output: true}
        },
        response_format: StructuredOutput.provider(schema, name: "answer")
      )

    {:ok, parent} = Tracing.start_run("agent", kind: :graph, metadata: %{thread_id: "thread-1"})

    assert %{structured_response: %{"ok" => true}} =
             ModelNode.invoke(node, %{messages: [Message.user("answer")]}, %{})

    assert {:ok, _finished_parent} = Tracing.finish_run(parent)

    sequence = run_by_name!("RunnableSequence")
    model = run_by_kind_child!(:model, sequence.id)

    assert sequence.parent_id == parent.id
    assert model.parent_id == sequence.id
    assert sequence.metadata.structured_output == true
    assert sequence.metadata.structured_output_schema == ["answer"]
    assert sequence.metadata.structured_output_strategy == :provider
    assert sequence.metadata.structured_output_requested_strategy == :provider
    assert sequence.metadata.structured_output_effective_strategy == :provider
    assert sequence.metadata.structured_output_fallback_reason == nil
    assert sequence.metadata.structured_output_schema_bytes > 0
    assert sequence.metadata.structured_output_schema_properties == 1
    assert model.metadata.thread_id == "thread-1"
    assert model.metadata.structured_output == :response_format
    assert model.metadata.structured_output_requested_strategy == :provider
    assert model.metadata.structured_output_effective_strategy == :provider
    refute Map.has_key?(model.metadata, :middleware)
    assert sequence.outputs == %{structured_response: %{"ok" => true}}
  end

  defp run_by_name!(name) do
    Store.list()
    |> Enum.find(&(&1.name == name))
    |> case do
      nil -> flunk("expected trace run named #{name}")
      run -> run
    end
  end

  defp run_by_kind_child!(kind, parent_id) do
    Store.list()
    |> Enum.find(&(&1.kind == kind and &1.parent_id == parent_id))
    |> case do
      nil -> flunk("expected trace run kind #{inspect(kind)} under #{parent_id}")
      run -> run
    end
  end
end
