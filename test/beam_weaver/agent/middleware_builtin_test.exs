defmodule BeamWeaver.Agent.MiddlewareBuiltinTest do
  use ExUnit.Case, async: true

  # Upstream references:
  # - langchain/libs/langchain_v1/tests/unit_tests/agents/middleware/implementations/test_tool_retry.py
  # - langchain/libs/langchain_v1/tests/unit_tests/agents/middleware/implementations/test_tool_call_limit.py
  # - langchain/libs/langchain_v1/tests/unit_tests/agents/middleware/implementations/test_tool_selection.py
  # - langchain/libs/langchain_v1/tests/unit_tests/agents/middleware/implementations/test_model_fallback.py
  # - langchain/libs/langchain_v1/tests/unit_tests/agents/middleware/implementations/test_summarization.py
  # - langchain/libs/langchain_v1/tests/unit_tests/agents/middleware/implementations/test_context_editing.py
  # - langchain/libs/langchain_v1/tests/unit_tests/agents/middleware/core/test_dynamic_tools.py

  alias BeamWeaver.Agent
  alias BeamWeaver.Agent.Decision
  alias BeamWeaver.Agent.FinalResponsePolicy
  alias BeamWeaver.Agent.Middleware.ContextEditing
  alias BeamWeaver.Agent.Middleware.ModelCallLimit
  alias BeamWeaver.Agent.Middleware.ModelFallback
  alias BeamWeaver.Agent.Middleware.ModelRetry
  alias BeamWeaver.Agent.Middleware.ToolCallLimit
  alias BeamWeaver.Agent.Middleware.ToolEmulator
  alias BeamWeaver.Agent.Middleware.ToolRetry
  alias BeamWeaver.Agent.Middleware.ToolSelection
  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Agent.ToolCallRequest
  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.ToolCall
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Models.FakeChatModel

  defmodule FlakyModel do
    @behaviour ChatModel

    defstruct [:table]

    @impl true
    def invoke(%__MODULE__{table: table}, _messages, opts) do
      table = table(table, opts)
      count = :ets.update_counter(table, :calls, 1, {:calls, 0})

      if count == 1 do
        {:error, Error.new(:temporary_model_error, "temporary")}
      else
        {:ok, Message.assistant("recovered")}
      end
    end

    defp table(:context, opts), do: opts |> Keyword.get(:context, %{}) |> Map.get(:table)
    defp table(table, _opts), do: table
  end

  defmodule FailingModel do
    @behaviour ChatModel

    defstruct []

    @impl true
    def invoke(%__MODULE__{}, _messages, _opts),
      do: {:error, Error.new(:primary_failed, "primary failed")}
  end

  defmodule RecordingModel do
    @behaviour ChatModel

    defstruct [:parent, :reply, tool_calls: nil]

    @impl true
    def invoke(%__MODULE__{} = model, messages, opts) do
      if parent = parent(model.parent, opts), do: send(parent, {:model_call, messages, opts})

      cond do
        Enum.any?(messages, &match?(%Message{role: :tool}, &1)) ->
          tool_count = Enum.count(messages, &match?(%Message{role: :tool}, &1))
          {:ok, Message.assistant("tool-count:#{tool_count}")}

        is_list(model.tool_calls) ->
          {:ok, Message.assistant("", tool_calls: model.tool_calls)}

        true ->
          {:ok, Message.assistant(model.reply || "ok")}
      end
    end

    defp parent(:context, opts), do: opts |> Keyword.get(:context, %{}) |> Map.get(:parent)
    defp parent(parent, _opts), do: parent
  end

  defmodule RunLimitModel do
    @behaviour ChatModel

    defstruct [:parent]

    @impl true
    def invoke(%__MODULE__{parent: parent}, messages, opts) do
      parent = parent(parent, opts)

      if parent do
        send(parent, {:run_limit_model_call, Enum.count(messages)})
        send(parent, {:model_call, messages, opts})
      end

      case Enum.find(messages, &match?(%Message{role: :tool}, &1)) do
        %Message{} ->
          {:ok, Message.assistant("should not run second model")}

        nil ->
          {:ok,
           Message.assistant("",
             tool_calls: [%{id: "call-echo", name: "echo", args: %{}}]
           )}
      end
    end

    defp parent(:context, opts), do: opts |> Keyword.get(:context, %{}) |> Map.get(:parent)
    defp parent(parent, _opts), do: parent
  end

  defmodule LoggingModelMiddleware do
    @behaviour BeamWeaver.Agent.Middleware

    defstruct []

    def new(_opts \\ []), do: %__MODULE__{}
    def name(_middleware), do: :logging_model_middleware

    def wrap_model_call(_middleware, request, handler) do
      send(request.runtime.context.parent, :before_model_wrapper)
      response = handler.(request)
      send(request.runtime.context.parent, :after_model_wrapper)
      response
    end
  end

  defmodule LoggingToolMiddleware do
    @behaviour BeamWeaver.Agent.Middleware

    defstruct []

    def new(_opts \\ []), do: %__MODULE__{}
    def name(_middleware), do: :logging_tool_middleware

    def wrap_tool_call(_middleware, request, handler) do
      name = Map.get(request.tool_call, :name) || Map.get(request.tool_call, "name")
      send(request.runtime.context.parent, {:before_tool_wrapper, name})
      response = handler.(request)
      send(request.runtime.context.parent, {:after_tool_wrapper, name})
      response
    end
  end

  defmodule RetryAgent do
    use BeamWeaver.Agent

    model(%FlakyModel{table: :context})
    middleware([{BeamWeaver.Agent.Middleware.ModelRetry, max_attempts: 2}])
  end

  defmodule RetryAliasAgent do
    use BeamWeaver.Agent

    model(%FlakyModel{table: :context})
    middleware([{BeamWeaver.Agent.Middleware.ModelRetry, max_retries: 1, initial_delay: 0}])
  end

  defmodule RetryFailureAgent do
    use BeamWeaver.Agent

    model(%FailingModel{})

    middleware([
      {BeamWeaver.Agent.Middleware.ModelRetry, max_retries: 1, initial_delay: 0, on_failure: :continue}
    ])
  end

  defmodule ModelRetryCompositionAgent do
    use BeamWeaver.Agent

    model(%RecordingModel{parent: :context, reply: "ok"})

    middleware([
      {LoggingModelMiddleware, []},
      {BeamWeaver.Agent.Middleware.ModelRetry, max_retries: 1, initial_delay: 0}
    ])
  end

  defmodule FallbackAgent do
    use BeamWeaver.Agent

    model(%FailingModel{})

    middleware([
      {BeamWeaver.Agent.Middleware.ModelFallback, fallbacks: [%RecordingModel{reply: "fallback"}]}
    ])
  end

  defmodule FallbackExhaustedAgent do
    use BeamWeaver.Agent

    model(%FailingModel{})

    middleware([
      {BeamWeaver.Agent.Middleware.ModelFallback, fallbacks: [%FailingModel{}, %FailingModel{}]}
    ])
  end

  defmodule PrimarySuccessFallbackAgent do
    use BeamWeaver.Agent

    model(%RecordingModel{reply: "primary"})

    middleware([
      {BeamWeaver.Agent.Middleware.ModelFallback, fallbacks: [%RecordingModel{reply: "fallback"}]}
    ])
  end

  defmodule MultipleFallbackAgent do
    use BeamWeaver.Agent

    model(%FailingModel{})

    middleware([
      {BeamWeaver.Agent.Middleware.ModelFallback,
       fallbacks: [%FailingModel{}, %RecordingModel{reply: "second fallback"}]}
    ])
  end

  defmodule FallbackPredicateAgent do
    use BeamWeaver.Agent

    model(%FailingModel{})

    middleware([
      {BeamWeaver.Agent.Middleware.ModelFallback,
       fallbacks: [%RecordingModel{reply: "should not run"}], retry_on: :other_error}
    ])
  end

  defmodule ToolLimitAgent do
    use BeamWeaver.Agent

    model(%RecordingModel{
      parent: :context,
      tool_calls: [
        %{id: "call-one", name: "echo", args: %{"value" => "one"}},
        %{id: "call-two", name: "echo", args: %{"value" => "two"}}
      ]
    })

    tools(__MODULE__.tools())
    middleware([{BeamWeaver.Agent.Middleware.ToolCallLimit, max_calls: 1}])

    def tools do
      [
        Tool.from_function!(
          name: "echo",
          description: "Echo",
          input_schema: %{
            "type" => "object",
            "required" => ["value"],
            "properties" => %{
              "value" => %{"type" => "string"},
              "context" => %{"type" => "object"}
            }
          },
          injected: [context: :context],
          handler: fn input, _opts ->
            send(input.context.parent, {:tool_executed, Map.delete(input, :context)})
            {:ok, input["value"] || input.value}
          end
        )
      ]
    end
  end

  defmodule ToolSelectionAgent do
    use BeamWeaver.Agent

    model(%RecordingModel{parent: :context})
    tools(__MODULE__.tools())
    middleware([{BeamWeaver.Agent.Middleware.ToolSelection, allow: ["public_tool"]}])

    def tools do
      [
        Tool.from_function!(
          name: "public_tool",
          description: "Public",
          input_schema: %{"type" => "object"},
          handler: fn input, _opts -> {:ok, input} end
        ),
        Tool.from_function!(
          name: "private_tool",
          description: "Private",
          input_schema: %{"type" => "object"},
          handler: fn input, _opts -> {:ok, input} end
        )
      ]
    end
  end

  defmodule PromptAgent do
    use BeamWeaver.Agent

    model(%RecordingModel{parent: :context})
    middleware([{BeamWeaver.Agent.Middleware.DynamicPrompt, prompt: &__MODULE__.prompt/1}])
    def prompt(request), do: "tenant=#{request.runtime.context.tenant}"
  end

  defmodule DynamicToolModel do
    @behaviour ChatModel

    defstruct [:parent]

    @impl true
    def invoke(%__MODULE__{parent: parent}, messages, opts) do
      parent = parent(parent, opts)

      send(
        parent,
        {:dynamic_tool_model_tools, Enum.map(Keyword.get(opts, :tools, []), &Tool.name/1)}
      )

      case Enum.find(messages, &match?(%Message{role: :tool}, &1)) do
        %Message{content: content} ->
          {:ok, Message.assistant("final: #{content}")}

        nil ->
          {:ok,
           Message.assistant("",
             tool_calls: [
               %{id: "call-dynamic", name: "dynamic_lookup", args: %{"query" => "elixir"}}
             ]
           )}
      end
    end

    defp parent(:context, opts), do: opts |> Keyword.get(:context, %{}) |> Map.get(:parent)
    defp parent(parent, _opts), do: parent
  end

  defmodule DynamicToolAgent do
    use BeamWeaver.Agent

    model(%DynamicToolModel{parent: :context})

    middleware([
      {BeamWeaver.Agent.Middleware.ToolSelection, tools: &__MODULE__.dynamic_tools/1}
    ])

    validate_tools(true)

    def dynamic_tools(request) do
      [
        Tool.from_function!(
          name: "dynamic_lookup",
          description: "Runtime lookup",
          input_schema: %{
            "type" => "object",
            "required" => ["query"],
            "properties" => %{"query" => %{"type" => "string"}}
          },
          injected: %{"context" => :context},
          handler: fn %{"query" => query, "context" => context}, _opts ->
            send(context.parent, {:dynamic_tool_executed, query, request.runtime.node})
            "dynamic:#{query}"
          end
        )
      ]
    end
  end

  defmodule ToolRetryCompositionModel do
    @behaviour ChatModel

    defstruct []

    @impl true
    def invoke(%__MODULE__{}, messages, _opts) do
      case Enum.find(messages, &match?(%Message{role: :tool}, &1)) do
        %Message{content: content} ->
          {:ok, Message.assistant("final: #{content}")}

        nil ->
          {:ok, Message.assistant("", tool_calls: [%{id: "call-log", name: "log_tool", args: %{}}])}
      end
    end
  end

  defmodule ToolRetryCompositionAgent do
    use BeamWeaver.Agent

    model(%ToolRetryCompositionModel{})
    tools(__MODULE__.tools())

    middleware([
      {LoggingToolMiddleware, []},
      {BeamWeaver.Agent.Middleware.ToolRetry, max_retries: 1, initial_delay: 0}
    ])

    def tools do
      [
        Tool.from_function!(
          name: "log_tool",
          description: "Log tool",
          input_schema: %{"type" => "object"},
          injected: [context: :context],
          handler: fn input, _opts ->
            send(input.context.parent, :log_tool_executed)
            {:ok, input}
          end
        )
      ]
    end
  end

  defmodule ToolRetryModel do
    @behaviour ChatModel

    defstruct []

    @impl true
    def invoke(%__MODULE__{}, messages, _opts) do
      case Enum.find(messages, &match?(%Message{role: :tool}, &1)) do
        %Message{content: content} ->
          {:ok, Message.assistant("final: #{content}")}

        nil ->
          {:ok, Message.assistant("", tool_calls: [%{id: "call-flaky", name: "flaky", args: %{}}])}
      end
    end
  end

  defmodule ToolRetryAgent do
    use BeamWeaver.Agent

    model(%ToolRetryModel{})
    tools(__MODULE__.tools())
    middleware([{BeamWeaver.Agent.Middleware.ToolRetry, max_attempts: 2}])

    def tools do
      [
        Tool.from_function!(
          name: "flaky",
          description: "Fails once",
          input_schema: %{"type" => "object"},
          injected: %{context: :context},
          handler: fn %{context: context}, _opts ->
            count = :ets.update_counter(context.table, :tool_calls, 1, {:tool_calls, 0})

            if count == 1 do
              {:error, Error.new(:temporary_tool_error, "temporary")}
            else
              "recovered"
            end
          end
        )
      ]
    end
  end

  defmodule ToolRetryPredicateAgent do
    use BeamWeaver.Agent

    model(%ToolRetryModel{})
    tools(__MODULE__.tools())

    middleware([
      {BeamWeaver.Agent.Middleware.ToolRetry, max_attempts: 3, retry_on: :retryable_tool_error}
    ])

    def tools do
      [
        Tool.from_function!(
          name: "flaky",
          description: "Non-retryable failure",
          input_schema: %{"type" => "object"},
          injected: %{context: :context},
          handler: fn %{context: context}, _opts ->
            :ets.update_counter(context.table, :tool_calls, 1, {:tool_calls, 0})
            {:error, Error.new(:non_retryable_tool_error, "do not retry")}
          end
        )
      ]
    end
  end

  defmodule ToolRetryFilterModel do
    @behaviour ChatModel

    defstruct []

    @impl true
    def invoke(%__MODULE__{}, messages, _opts) do
      case Enum.filter(messages, &match?(%Message{role: :tool}, &1)) do
        [] ->
          {:ok,
           Message.assistant("",
             tool_calls: [
               %{id: "call-flaky", name: "flaky", args: %{}},
               %{id: "call-plain", name: "plain", args: %{}}
             ]
           )}

        tool_messages ->
          contents = Enum.map_join(tool_messages, ",", & &1.content)
          {:ok, Message.assistant("final: #{contents}")}
      end
    end
  end

  defmodule ToolRetryFilterAgent do
    use BeamWeaver.Agent

    model(%ToolRetryFilterModel{})
    tools(__MODULE__.tools())

    middleware([
      {BeamWeaver.Agent.Middleware.ToolRetry, max_retries: 1, initial_delay: 0, tools: ["flaky"]}
    ])

    def tools do
      [
        Tool.from_function!(
          name: "flaky",
          description: "Retried",
          input_schema: %{"type" => "object"},
          injected: %{context: :context},
          handler: fn %{context: context}, _opts ->
            count = :ets.update_counter(context.table, :flaky, 1, {:flaky, 0})

            if count == 1 do
              {:error, Error.new(:temporary_tool_error, "temporary")}
            else
              "flaky recovered"
            end
          end
        ),
        Tool.from_function!(
          name: "plain",
          description: "Not retried",
          input_schema: %{"type" => "object"},
          injected: %{context: :context},
          handler: fn %{context: context}, _opts ->
            :ets.update_counter(context.table, :plain, 1, {:plain, 0})
            {:error, Error.new(:plain_tool_error, "plain failed")}
          end
        )
      ]
    end
  end

  defmodule ToolRetryContinueAgent do
    use BeamWeaver.Agent

    model(%ToolRetryModel{})
    tools(__MODULE__.tools())

    middleware([
      {BeamWeaver.Agent.Middleware.ToolRetry, max_retries: 1, initial_delay: 0, on_failure: :continue}
    ])

    def tools do
      [
        Tool.from_function!(
          name: "flaky",
          description: "Always fails",
          input_schema: %{"type" => "object"},
          injected: %{context: :context},
          handler: fn %{context: context}, _opts ->
            :ets.update_counter(context.table, :tool_calls, 1, {:tool_calls, 0})
            {:error, Error.new(:temporary_tool_error, "temporary")}
          end
        )
      ]
    end
  end

  defmodule ModelCallLimitAgent do
    use BeamWeaver.Agent

    model(%RecordingModel{reply: "blocked"})
    middleware([{BeamWeaver.Agent.Middleware.ModelCallLimit, max_calls: 0}])
  end

  defmodule ModelCallLimitEndAgent do
    use BeamWeaver.Agent

    model(%RecordingModel{parent: :context, reply: "blocked"})

    middleware([
      {BeamWeaver.Agent.Middleware.ModelCallLimit, thread_limit: 0, exit_behavior: :end}
    ])
  end

  defmodule ModelRunLimitAgent do
    use BeamWeaver.Agent

    model(%RunLimitModel{parent: :context})
    tools(__MODULE__.tools())
    middleware([{BeamWeaver.Agent.Middleware.ModelCallLimit, run_limit: 1, exit_behavior: :end}])

    def tools do
      [
        Tool.from_function!(
          name: "echo",
          description: "Echo",
          input_schema: %{"type" => "object"},
          injected: [context: :context],
          handler: fn input, _opts ->
            send(input.context.parent, {:run_limit_tool_executed, :echo})
            {:ok, "done"}
          end
        )
      ]
    end
  end

  defmodule ToolSelectionComplexAgent do
    use BeamWeaver.Agent

    model(%RecordingModel{parent: :context})
    tools(__MODULE__.tools())

    middleware([
      {BeamWeaver.Agent.Middleware.ToolSelection,
       deny: ["denied"],
       tags: [:public],
       metadata: %{scope: :docs},
       predicate: fn tool, request ->
         Tool.name(tool) != "predicate_blocked" and request.runtime.context.allow_tools == true
       end}
    ])

    def tools do
      [
        named_tool("allowed", tags: [:public], metadata: %{scope: :docs}),
        named_tool("denied", tags: [:public], metadata: %{scope: :docs}),
        named_tool("wrong_tag", tags: [:private], metadata: %{scope: :docs}),
        named_tool("wrong_metadata", tags: [:public], metadata: %{scope: :billing}),
        named_tool("predicate_blocked", tags: [:public], metadata: %{scope: :docs})
      ]
    end

    defp named_tool(name, opts) do
      Tool.from_function!(
        name: name,
        description: name,
        input_schema: %{"type" => "object"},
        tags: Keyword.fetch!(opts, :tags),
        metadata: Keyword.fetch!(opts, :metadata),
        handler: fn input, _opts -> input end
      )
    end
  end

  defmodule SummaryModel do
    @behaviour ChatModel

    defstruct []

    @impl true
    def invoke(%__MODULE__{}, _messages, _opts), do: {:ok, Message.assistant("old summary")}
  end

  defmodule ProfileSummaryModel do
    @behaviour ChatModel

    defstruct [
      :parent,
      profile: %BeamWeaver.Models.Profile{provider: :openai, max_input_tokens: 1_000}
    ]

    @impl true
    def invoke(%__MODULE__{parent: parent}, messages, _opts) do
      if parent, do: send(parent, {:summary_prompt, messages})
      {:ok, Message.assistant("profile summary")}
    end
  end

  defmodule CapturingSummaryModel do
    @behaviour ChatModel

    defstruct [
      :parent,
      profile: %BeamWeaver.Models.Profile{provider: :openai, max_input_tokens: 1_000}
    ]

    @impl true
    def invoke(%__MODULE__{parent: parent}, messages, opts) do
      if parent, do: send(parent, {:captured_summary_call, messages, opts})
      {:ok, Message.assistant("captured summary")}
    end
  end

  defmodule SummarizationAgent do
    use BeamWeaver.Agent

    model(%RecordingModel{reply: "summarized"})

    middleware([
      {BeamWeaver.Agent.Middleware.Summarization, model: %SummaryModel{}, trigger: {:messages, 2}, keep: {:messages, 1}}
    ])
  end

  defmodule ContextEditingAgent do
    use BeamWeaver.Agent

    model(%RecordingModel{parent: :context, reply: "edited"})

    middleware([
      {BeamWeaver.Agent.Middleware.ContextEditing,
       trigger: 0, keep: 1, clear_tool_inputs: true, exclude_tools: ["keep_tool"]}
    ])
  end

  defmodule ToolLimitEndAgent do
    use BeamWeaver.Agent

    model(%RecordingModel{
      parent: :context,
      tool_calls: [%{id: "call-one", name: "echo", args: %{"value" => "one"}}]
    })

    tools(__MODULE__.tools())
    middleware([{BeamWeaver.Agent.Middleware.ToolCallLimit, run_limit: 0, exit_behavior: :end}])

    def tools do
      [
        Tool.from_function!(
          name: "echo",
          description: "Echo",
          input_schema: %{"type" => "object"},
          injected: [context: :context],
          handler: fn input, _opts ->
            send(input.context.parent, {:end_tool_executed, Map.delete(input, :context)})
            {:ok, "unexpected"}
          end
        )
      ]
    end
  end

  defmodule ToolLimitSpecificAgent do
    use BeamWeaver.Agent

    model(%RecordingModel{
      parent: :context,
      tool_calls: [
        %{id: "call-limited", name: "limited", args: %{}},
        %{id: "call-open", name: "open", args: %{}}
      ]
    })

    tools(__MODULE__.tools())

    middleware([
      {BeamWeaver.Agent.Middleware.ToolCallLimit, tool_name: "limited", thread_limit: 0, exit_behavior: :continue}
    ])

    def tools do
      [
        Tool.from_function!(
          name: "limited",
          description: "Limited",
          input_schema: %{"type" => "object"},
          injected: [context: :context],
          handler: fn input, _opts ->
            send(input.context.parent, {:limited_tool_executed, :limited})
            {:ok, "limited"}
          end
        ),
        Tool.from_function!(
          name: "open",
          description: "Open",
          input_schema: %{"type" => "object"},
          injected: [context: :context],
          handler: fn input, _opts ->
            send(input.context.parent, {:open_tool_executed, :open})
            {:ok, "open"}
          end
        )
      ]
    end
  end

  defmodule ToolRunLimitAgent do
    use BeamWeaver.Agent

    model(%RecordingModel{
      parent: :context,
      tool_calls: [
        %{id: "call-one", name: "echo", args: %{"value" => "one"}},
        %{id: "call-two", name: "echo", args: %{"value" => "two"}}
      ]
    })

    tools(ToolLimitAgent.tools())
    middleware([{BeamWeaver.Agent.Middleware.ToolCallLimit, run_limit: 1}])
  end

  defmodule DecisionMiddleware do
    @behaviour BeamWeaver.Agent.Middleware

    def name(_middleware), do: :decision_middleware

    def before_model(_state, _runtime) do
      %Decision.Jump{
        destination: :end,
        update: %{messages: [Message.assistant("typed decision")]}
      }
    end
  end

  defmodule DecisionAgent do
    use BeamWeaver.Agent

    model(%RecordingModel{parent: :context, reply: "should not run"})
    middleware([DecisionMiddleware])
  end

  defmodule PromptListAgent do
    use BeamWeaver.Agent

    model(%RecordingModel{parent: :context, reply: "done"})
    middleware([{BeamWeaver.Agent.Middleware.DynamicPrompt, prompt: &__MODULE__.prompt/1}])

    def prompt(_request) do
      [
        Message.system("system one"),
        Message.user("few-shot user"),
        Message.assistant("few-shot assistant")
      ]
    end
  end

  defmodule UsageModel do
    @behaviour ChatModel

    defstruct []

    @impl true
    def invoke(%__MODULE__{}, _messages, _opts) do
      {:ok,
       Message.assistant("with usage",
         usage_metadata: %{input_tokens: 3, output_tokens: 2, total_tokens: 5}
       )}
    end
  end

  defmodule UsageAgent do
    use BeamWeaver.Agent

    model(%UsageModel{})
  end

  defmodule SchemaAgent do
    use BeamWeaver.Agent

    input_schema(%{messages: BeamWeaver.Agent.Schema.field(:messages, :list, required: true)})
    output_schema(%{messages: BeamWeaver.Agent.Schema.field(:messages, :list, required: true)})
    model(%RecordingModel{reply: "schema ok"})
  end

  defmodule PIIAgent do
    use BeamWeaver.Agent

    model(%RecordingModel{parent: :context})
    middleware([{BeamWeaver.Agent.Middleware.PII, strategy: :block}])
  end

  defmodule PIIEditAgent do
    use BeamWeaver.Agent

    model(%RecordingModel{parent: :context})
    middleware(__MODULE__.middleware())

    def middleware do
      [
        {BeamWeaver.Agent.Middleware.PII,
         detectors: [:email, :credit_card, :ip, :mac, :url], strategy: :redact, replacement: "[X]"}
      ]
    end
  end

  defmodule PIIMultipleAgent do
    use BeamWeaver.Agent

    model(%RecordingModel{parent: :context})

    middleware([
      {BeamWeaver.Agent.Middleware.PII, type: :email, strategy: :redact},
      {BeamWeaver.Agent.Middleware.PII, type: :ip, strategy: :mask},
      {BeamWeaver.Agent.Middleware.PII, type: :url, strategy: :block}
    ])
  end

  test "model retry reuses the shared retry policy in a real agent" do
    table = :ets.new(:retry_agent, [:set, :public])

    assert {:ok, %{messages: messages}} =
             Agent.invoke(RetryAgent, %{messages: [Message.user("hello")]}, context: %{table: table})

    assert Enum.any?(messages, &match?(%Message{role: :assistant, content: "recovered"}, &1))
    assert :ets.lookup(table, :calls) == [{:calls, 2}]
  end

  test "model retry accepts native retry policy options and can continue with an assistant error message" do
    assert_raise ArgumentError, fn ->
      ModelRetry.new(max_retries: -1)
    end

    assert %ModelRetry{policy: %{max_attempts: 1} = policy} =
             ModelRetry.new(max_retries: 0, backoff: 0.0, initial_delay: 0)

    assert policy.backoff == 0.0

    alias_table = :ets.new(:retry_agent_native_opts, [:set, :public])

    assert {:ok, %{messages: messages}} =
             Agent.invoke(RetryAliasAgent, %{messages: [Message.user("hello")]}, context: %{table: alias_table})

    assert Enum.any?(messages, &match?(%Message{role: :assistant, content: "recovered"}, &1))
    assert :ets.lookup(alias_table, :calls) == [{:calls, 2}]

    assert {:ok, %{messages: messages}} =
             Agent.invoke(RetryFailureAgent, %{messages: [Message.user("hello")]})

    assert %Message{role: :assistant, content: content, metadata: %{status: "error"}} =
             List.last(messages)

    assert content =~ "Model call failed after 2 attempts"
    assert content =~ "primary_failed"
  end

  test "model retry supports custom retry predicates and failure formatting" do
    table = :ets.new(:model_retry_predicate, [:set, :public])

    policy =
      BeamWeaver.RetryPolicy.new!(
        max_attempts: 3,
        initial_delay: 0,
        retry_on: fn
          %Error{type: :retryable_model_error} -> true
          _error -> false
        end
      )

    assert {:error, %Error{type: :non_retryable_model_error}} =
             ModelRetry.retry(
               policy,
               1,
               fn ->
                 count = :ets.update_counter(table, :calls, 1, {:calls, 0})

                 if count == 1 do
                   {:error, Error.new(:retryable_model_error, "retry")}
                 else
                   {:error, Error.new(:non_retryable_model_error, "stop")}
                 end
               end,
               [:beam_weaver, :test, :model_retry]
             )

    assert :ets.lookup(table, :calls) == [{:calls, 2}]

    middleware =
      ModelRetry.new(
        max_retries: 0,
        on_failure: fn error -> "Custom error: #{error.type}" end
      )

    assert %Message{role: :assistant, content: "Custom error: primary_failed"} =
             ModelRetry.wrap_model_call(middleware, %ModelRequest{}, fn _request ->
               {:error, Error.new(:primary_failed, "primary failed")}
             end)

    assert {:error, %Error{type: :primary_failed}} =
             ModelRetry.wrap_model_call(
               ModelRetry.new(max_retries: 0, on_failure: :error),
               %ModelRequest{},
               fn _request -> {:error, Error.new(:primary_failed, "primary failed")} end
             )
  end

  test "model retry composes with other model-call wrappers" do
    parent = self()

    assert {:ok, %{messages: messages}} =
             Agent.invoke(ModelRetryCompositionAgent, %{messages: [Message.user("hello")]}, context: %{parent: parent})

    assert_received :before_model_wrapper
    assert_received :after_model_wrapper
    assert Enum.any?(messages, &match?(%Message{role: :assistant, content: "ok"}, &1))
  end

  test "model fallback preserves the request and returns fallback response" do
    assert {:ok, %{messages: messages}} =
             Agent.invoke(FallbackAgent, %{messages: [Message.user("hello")]})

    assert Enum.any?(messages, &match?(%Message{role: :assistant, content: "fallback"}, &1))
  end

  test "model fallback returns the final fallback error when all models fail" do
    # Upstream reference:
    # langchain/libs/langchain_v1/tests/unit_tests/agents/middleware/implementations/test_model_fallback.py
    assert {:error, %Error{type: :primary_failed}} =
             Agent.invoke(FallbackExhaustedAgent, %{messages: [Message.user("hello")]})
  end

  test "model fallback handles primary success, multiple fallbacks, predicates, and immutable requests" do
    assert {:ok, %{messages: messages}} =
             Agent.invoke(PrimarySuccessFallbackAgent, %{messages: [Message.user("hello")]})

    assert Enum.any?(messages, &match?(%Message{role: :assistant, content: "primary"}, &1))

    assert {:ok, %{messages: messages}} =
             Agent.invoke(MultipleFallbackAgent, %{messages: [Message.user("hello")]})

    assert Enum.any?(
             messages,
             &match?(%Message{role: :assistant, content: "second fallback"}, &1)
           )

    assert {:error, %Error{type: :primary_failed}} =
             Agent.invoke(FallbackPredicateAgent, %{messages: [Message.user("hello")]})

    primary = %FailingModel{}
    fallback = %RecordingModel{reply: "fallback"}
    middleware = ModelFallback.new(fallbacks: [fallback])
    request = %ModelRequest{model: primary, messages: [Message.user("hello")], tools: []}

    assert {:ok, %Message{content: "fallback"}} =
             ModelFallback.wrap_model_call(middleware, request, fn
               %ModelRequest{model: ^primary} -> {:error, Error.new(:primary_failed, "failed")}
               %ModelRequest{model: ^fallback} -> {:ok, Message.assistant("fallback")}
             end)

    assert request.model == primary
  end

  test "tool call limit satisfies over-limit calls and executes only allowed calls" do
    parent = self()

    assert {:ok, %{messages: messages}} =
             Agent.invoke(ToolLimitAgent, %{messages: [Message.user("tools")]}, context: %{parent: parent})

    assert_received {:tool_executed, %{"value" => "one"}}
    refute_received {:tool_executed, %{"value" => "two"}}

    assert Enum.any?(messages, fn
             %Message{
               role: :tool,
               tool_call_id: "call-two",
               metadata: %{error_type: :tool_call_limit_exceeded}
             } ->
               true

             _other ->
               false
           end)
  end

  test "tool selection filters model-visible tools" do
    parent = self()

    assert {:ok, _state} =
             Agent.invoke(ToolSelectionAgent, %{messages: [Message.user("hello")]}, context: %{parent: parent})

    assert_received {:model_call, _messages, opts}
    assert Enum.map(Keyword.fetch!(opts, :tools), &Tool.name/1) == ["public_tool"]
  end

  test "dynamic prompt replaces the model system message" do
    parent = self()

    assert {:ok, _state} =
             Agent.invoke(PromptAgent, %{messages: [Message.user("hello")]}, context: %{parent: parent, tenant: "acme"})

    assert_received {:model_call, [%Message{role: :system, content: "tenant=acme"} | _], _opts}
  end

  test "dynamic prompt can provide a message list" do
    parent = self()

    assert {:ok, _state} =
             Agent.invoke(PromptListAgent, %{messages: [Message.user("hello")]}, context: %{parent: parent})

    assert_received {:model_call, messages, _opts}

    assert Enum.map(messages, &{&1.role, &1.content}) == [
             {:system, "system one"},
             {:user, "few-shot user"},
             {:assistant, "few-shot assistant"},
             {:user, "hello"}
           ]
  end

  test "dynamic tools are scoped through ToolSet for validation and ToolNode execution" do
    parent = self()

    assert {:ok, %{messages: messages}} =
             Agent.invoke(DynamicToolAgent, %{messages: [Message.user("lookup")]}, context: %{parent: parent})

    assert_received {:dynamic_tool_model_tools, ["dynamic_lookup"]}
    assert_received {:dynamic_tool_executed, "elixir", _node}
    assert Enum.any?(messages, &match?(%Message{role: :tool, content: "dynamic:elixir"}, &1))
    assert %Message{role: :assistant, content: "final: dynamic:elixir"} = List.last(messages)
  end

  test "tool retry retries a failed tool message and preserves the original tool call" do
    table = :ets.new(:tool_retry_agent, [:set, :public])

    assert {:ok, %{messages: messages}} =
             Agent.invoke(ToolRetryAgent, %{messages: [Message.user("run tool")]}, context: %{table: table})

    assert :ets.lookup(table, :tool_calls) == [{:tool_calls, 2}]
    assert Enum.any?(messages, &match?(%Message{role: :tool, content: "recovered"}, &1))
    assert %Message{role: :assistant, content: "final: recovered"} = List.last(messages)
  end

  test "tool retry respects retry_on predicates and does not retry non-matching errors" do
    # Upstream reference:
    # langchain/libs/langchain_v1/tests/unit_tests/agents/middleware/implementations/test_tool_retry.py
    table = :ets.new(:tool_retry_predicate_agent, [:set, :public])

    assert {:ok, %{messages: messages}} =
             Agent.invoke(ToolRetryPredicateAgent, %{messages: [Message.user("run tool")]}, context: %{table: table})

    assert :ets.lookup(table, :tool_calls) == [{:tool_calls, 1}]

    assert Enum.any?(messages, fn
             %Message{role: :tool, metadata: %{error_type: :non_retryable_tool_error}} -> true
             _message -> false
           end)
  end

  test "tool retry filters by tool name and can continue with a formatted tool message" do
    assert_raise ArgumentError, fn ->
      ToolRetry.new(max_retries: -1)
    end

    flaky_tool =
      Tool.from_function!(
        name: "flaky",
        description: "Flaky",
        input_schema: %{"type" => "object"},
        handler: fn input, _opts -> {:ok, input} end
      )

    assert %ToolRetry{tools: tools} = ToolRetry.new(tools: [flaky_tool, "plain"])
    assert MapSet.equal?(tools, MapSet.new(["flaky", "plain"]))

    assert %ToolRetry{policy: %{max_attempts: 1}, on_failure: :continue} =
             ToolRetry.new(max_retries: 0, on_failure: :return_message, tools: [:flaky])

    assert %ToolRetry{on_failure: :error} = ToolRetry.new(on_failure: :raise)

    table = :ets.new(:tool_retry_filter_agent, [:set, :public])

    assert {:ok, %{messages: messages}} =
             Agent.invoke(ToolRetryFilterAgent, %{messages: [Message.user("run tools")]}, context: %{table: table})

    assert :ets.lookup(table, :flaky) == [{:flaky, 2}]
    assert :ets.lookup(table, :plain) == [{:plain, 1}]
    assert Enum.any?(messages, &match?(%Message{role: :tool, content: "flaky recovered"}, &1))

    assert Enum.any?(messages, fn
             %Message{role: :tool, name: "plain", metadata: %{error_type: :plain_tool_error}} ->
               true

             _message ->
               false
           end)

    table = :ets.new(:tool_retry_continue_agent, [:set, :public])

    assert {:ok, %{messages: messages}} =
             Agent.invoke(ToolRetryContinueAgent, %{messages: [Message.user("run tool")]}, context: %{table: table})

    assert :ets.lookup(table, :tool_calls) == [{:tool_calls, 2}]

    assert Enum.any?(messages, fn
             %Message{
               role: :tool,
               content: content,
               metadata: %{status: "error", error_type: :temporary_tool_error}
             } ->
               content =~ "Tool 'flaky' failed after 2 attempts"

             _message ->
               false
           end)
  end

  test "tool retry supports custom retry predicates and failure formatting" do
    table = :ets.new(:tool_retry_custom_predicate, [:set, :public])

    middleware =
      ToolRetry.new(
        max_retries: 2,
        initial_delay: 0,
        retry_on: fn
          %Error{type: :retryable_tool_error} -> true
          _error -> false
        end,
        on_failure: fn error -> "Custom tool error: #{error.type}" end
      )

    request = %{
      tool: nil,
      tool_call: %{id: "call-custom", name: "custom_tool", args: %{}}
    }

    assert %Message{
             role: :tool,
             content: "Custom tool error: non_retryable_tool_error",
             tool_call_id: "call-custom",
             metadata: %{status: "error", error_type: :non_retryable_tool_error}
           } =
             ToolRetry.wrap_tool_call(middleware, request, fn _request ->
               count = :ets.update_counter(table, :calls, 1, {:calls, 0})

               if count == 1 do
                 Message.tool("retry",
                   tool_call_id: "call-custom",
                   name: "custom_tool",
                   metadata: %{status: "error", error_type: :retryable_tool_error}
                 )
               else
                 Message.tool("stop",
                   tool_call_id: "call-custom",
                   name: "custom_tool",
                   metadata: %{status: "error", error_type: :non_retryable_tool_error}
                 )
               end
             end)

    assert :ets.lookup(table, :calls) == [{:calls, 2}]

    assert {:error, %Error{type: :non_retryable_tool_error}} =
             ToolRetry.wrap_tool_call(
               ToolRetry.new(max_retries: 0, on_failure: :error),
               request,
               fn _request -> {:error, Error.new(:non_retryable_tool_error, "stop")} end
             )
  end

  test "tool retry composes with other tool-call wrappers" do
    parent = self()

    assert {:ok, %{messages: messages}} =
             Agent.invoke(ToolRetryCompositionAgent, %{messages: [Message.user("run tool")]},
               context: %{parent: parent}
             )

    assert_received {:before_tool_wrapper, "log_tool"}
    assert_received :log_tool_executed
    assert_received {:after_tool_wrapper, "log_tool"}
    assert %Message{role: :assistant, content: "final: " <> _json} = List.last(messages)
  end

  test "model call limit fails before invoking the model" do
    assert {:error, %Error{type: :model_call_limit_exceeded}} =
             Agent.invoke(ModelCallLimitAgent, %{messages: [Message.user("hello")]})
  end

  test "model call limit can end the agent with a tagged assistant message" do
    parent = self()

    assert {:ok, %{messages: messages}} =
             Agent.invoke(ModelCallLimitEndAgent, %{messages: [Message.user("hello")]}, context: %{parent: parent})

    refute_received {:model_call, _messages, _opts}

    assert [
             %Message{role: :user, content: "hello"},
             %Message{
               role: :assistant,
               content: "Model call limits exceeded: thread limit (0/0)",
               metadata: %{error_type: :model_call_limit_exceeded}
             }
           ] = messages
  end

  test "model call limit validates native options and increments private counters" do
    assert_raise ArgumentError, fn ->
      ModelCallLimit.new(thread_limit: nil, run_limit: nil)
    end

    assert_raise ArgumentError, fn ->
      ModelCallLimit.new(thread_limit: -1)
    end

    middleware = ModelCallLimit.new(thread_limit: 2, run_limit: 1, exit_behavior: "end")

    assert ModelCallLimit.after_model(
             middleware,
             %{thread_model_call_count: 1, run_model_call_count: 0},
             nil
           ) == %{thread_model_call_count: 2, run_model_call_count: 1}

    assert %{
             jump_to: :end,
             messages: [
               %Message{
                 role: :assistant,
                 metadata: %{error_type: :model_call_limit_exceeded}
               }
             ]
           } =
             ModelCallLimit.before_model(
               middleware,
               %{thread_model_call_count: 1, run_model_call_count: 1},
               nil
             )
  end

  test "model run limit resets between agent invocations" do
    parent = self()

    for _run <- 1..2 do
      assert {:ok, %{messages: messages}} =
               Agent.invoke(ModelRunLimitAgent, %{messages: [Message.user("run")]}, context: %{parent: parent})

      assert_received {:run_limit_model_call, 1}
      assert_received {:model_call, _messages, _opts}
      assert_received {:run_limit_tool_executed, :echo}
      refute_received {:run_limit_model_call, 3}

      assert %Message{role: :assistant, content: content} = List.last(messages)
      assert content =~ "Model call limits exceeded"
      assert content =~ "run limit (1/1)"
    end
  end

  test "tool selection filters by deny list, tags, metadata, predicate, and context" do
    parent = self()

    assert {:ok, _state} =
             Agent.invoke(ToolSelectionComplexAgent, %{messages: [Message.user("hello")]},
               context: %{parent: parent, allow_tools: true}
             )

    assert_received {:model_call, _messages, opts}
    assert Enum.map(Keyword.fetch!(opts, :tools), &Tool.name/1) == ["allowed"]
  end

  test "tool selection can use a native selector model with max tools and always include" do
    parent = self()

    middleware =
      ToolSelection.new(
        model: %FakeChatModel{
          parent: parent,
          structured_response: %{tools: ["weather", "weather", "search", "math"]}
        },
        max_tools: 2,
        always_include: [:email]
      )

    request =
      tool_selection_request(
        tools: [
          selection_tool("weather"),
          selection_tool("search"),
          selection_tool("math"),
          selection_tool("email")
        ]
      )

    assert {:ok, %ModelRequest{} = selected_request} =
             ToolSelection.wrap_model_call(middleware, request, fn request -> {:ok, request} end)

    assert Enum.map(selected_request.tools, &Tool.name/1) == ["weather", "search", "email"]

    assert_received {:fake_chat_model_call,
                     [
                       %Message{role: :system, content: system_prompt},
                       %Message{role: :user, content: "find weather"}
                     ], opts}

    assert system_prompt =~ "only the first 2 will be used"

    assert get_in(Keyword.fetch!(opts, :response_format), [
             :schema,
             "properties",
             "tools",
             "items",
             "enum"
           ]) == ["weather", "search", "math"]
  end

  test "tool selection uses request model by default and keeps all selected tools without a max" do
    middleware = ToolSelection.new(system_prompt: "pick tools")

    request =
      tool_selection_request(
        model: %FakeChatModel{structured_response: %{tools: ["math", "weather", "search"]}},
        tools: [selection_tool("weather"), selection_tool("search"), selection_tool("math")]
      )

    assert {:ok, %ModelRequest{} = selected_request} =
             ToolSelection.wrap_model_call(middleware, request, fn request -> {:ok, request} end)

    assert Enum.map(selected_request.tools, &Tool.name/1) == ["math", "weather", "search"]
  end

  test "tool selection parses tool-call selector responses" do
    middleware =
      ToolSelection.new(
        model: %FakeChatModel{
          tool_calls: [
            %{
              id: "selection-1",
              name: "ToolSelectionResponse",
              args: %{tools: ["search"]}
            }
          ]
        },
        max_tools: 1
      )

    request =
      tool_selection_request(tools: [selection_tool("weather"), selection_tool("search"), selection_tool("math")])

    assert {:ok, %ModelRequest{} = selected_request} =
             ToolSelection.wrap_model_call(middleware, request, fn request -> {:ok, request} end)

    assert Enum.map(selected_request.tools, &Tool.name/1) == ["search"]
  end

  test "tool selection reports invalid selections and missing always-include tools as tagged errors" do
    request =
      tool_selection_request(tools: [selection_tool("weather"), selection_tool("search")])

    invalid_selection =
      ToolSelection.new(
        model: %FakeChatModel{structured_response: %{tools: ["unknown"]}},
        max_tools: 1
      )

    assert {:error, %Error{type: :invalid_tool_selection, details: %{invalid_tools: ["unknown"]}}} =
             ToolSelection.wrap_model_call(invalid_selection, request, fn request ->
               {:ok, request}
             end)

    missing_required =
      ToolSelection.new(
        model: %FakeChatModel{structured_response: %{tools: ["weather"]}},
        always_include: ["email"]
      )

    assert {:error, %Error{type: :invalid_tool_selection, details: %{missing_tools: ["email"]}}} =
             ToolSelection.wrap_model_call(missing_required, request, fn request ->
               {:ok, request}
             end)
  end

  test "tool call limit end behavior stops before executing blocked tools" do
    parent = self()

    assert {:ok, %{messages: messages}} =
             Agent.invoke(ToolLimitEndAgent, %{messages: [Message.user("tools")]}, context: %{parent: parent})

    refute_received {:end_tool_executed, _input}

    assert Enum.any?(messages, fn
             %Message{
               role: :tool,
               tool_call_id: "call-one",
               metadata: %{error_type: :tool_call_limit_exceeded}
             } ->
               true

             _message ->
               false
           end)

    assert %Message{role: :assistant, content: content} = List.last(messages)
    assert content =~ "Tool call limit reached"
    assert content =~ "run limit exceeded (1/0 calls)"
  end

  test "tool call limit can apply to one tool while other calls continue" do
    parent = self()

    assert {:ok, %{messages: messages}} =
             Agent.invoke(ToolLimitSpecificAgent, %{messages: [Message.user("tools")]}, context: %{parent: parent})

    refute_received {:limited_tool_executed, :limited}
    assert_received {:open_tool_executed, :open}

    assert Enum.any?(messages, fn
             %Message{
               role: :tool,
               tool_call_id: "call-limited",
               metadata: %{error_type: :tool_call_limit_exceeded, tool_name: "limited"}
             } ->
               true

             _message ->
               false
           end)

    assert Enum.any?(messages, &match?(%Message{role: :tool, content: "open"}, &1))
  end

  test "tool run limit resets between agent invocations" do
    parent = self()

    for _run <- 1..2 do
      assert {:ok, %{messages: messages}} =
               Agent.invoke(ToolRunLimitAgent, %{messages: [Message.user("tools")]}, context: %{parent: parent})

      assert_received {:tool_executed, %{"value" => "one"}}
      refute_received {:tool_executed, %{"value" => "two"}}

      assert Enum.any?(messages, fn
               %Message{
                 role: :tool,
                 tool_call_id: "call-two",
                 metadata: %{error_type: :tool_call_limit_exceeded}
               } ->
                 true

               _message ->
                 false
             end)
    end
  end

  test "tool call limit validates options, names scoped instances, and reports errors" do
    assert_raise ArgumentError, fn ->
      ToolCallLimit.new(thread_limit: nil, run_limit: nil)
    end

    assert_raise ArgumentError, fn ->
      ToolCallLimit.new(thread_limit: 1, run_limit: 2)
    end

    assert ToolCallLimit.name(ToolCallLimit.new(tool_name: "search")) ==
             :"tool_call_limit:search"

    middleware = ToolCallLimit.new(tool_name: "search", thread_limit: 0, exit_behavior: :error)

    state = %{
      messages: [
        Message.assistant("",
          tool_calls: [%{id: "call-search", name: "search", args: %{}}]
        )
      ]
    }

    assert {:error, %Error{type: :tool_call_limit_exceeded, details: details}} =
             ToolCallLimit.after_model(middleware, state, nil)

    assert details.tool_name == "search"
    assert details.thread_limit == 0
  end

  test "tool call limit direct behavior tracks blocked calls without counting them against thread limits" do
    middleware = ToolCallLimit.new(tool_name: "limited", thread_limit: 1, run_limit: 1)

    state = %{
      thread_tool_call_count: %{"limited" => 0},
      run_tool_call_count: %{"limited" => 0},
      messages: [
        Message.user("first request"),
        Message.user("second request"),
        Message.assistant("",
          tool_calls: [
            %{id: "call-one", name: "limited", args: %{}},
            %{id: "call-two", name: "limited", args: %{}}
          ]
        )
      ]
    }

    assert %{
             thread_tool_call_count: %{"limited" => 1},
             run_tool_call_count: %{"limited" => 2},
             messages: [
               %Message{role: :tool, tool_call_id: "call-two", metadata: metadata}
             ]
           } = ToolCallLimit.after_model(middleware, state, nil)

    assert metadata.error_type == :tool_call_limit_exceeded
  end

  test "tool call limit supports multiple scoped middleware instances as private count maps" do
    search = ToolCallLimit.new(tool_name: "search", thread_limit: 0)
    write = ToolCallLimit.new(tool_name: "write", thread_limit: 0)

    state = %{
      messages: [
        Message.user("two tools"),
        Message.assistant("",
          tool_calls: [
            %{id: "call-search", name: "search", args: %{}},
            %{id: "call-write", name: "write", args: %{}}
          ]
        )
      ]
    }

    assert %{messages: [search_blocked] = search_messages} =
             search_update = ToolCallLimit.after_model(search, state, nil)

    next_state =
      state
      |> Map.merge(Map.drop(search_update, [:messages]))
      |> Map.update!(:messages, &(&1 ++ search_messages))

    assert %{messages: [write_blocked]} =
             write_update = ToolCallLimit.after_model(write, next_state, nil)

    assert search_blocked.tool_call_id == "call-search"
    assert write_blocked.tool_call_id == "call-write"
    assert write_update.thread_tool_call_count == %{"search" => 0, "write" => 0}
  end

  test "tool call limit end mode handles multiple blocked parallel calls for the scoped set" do
    middleware = ToolCallLimit.new(thread_limit: 0, exit_behavior: :end)

    state = %{
      messages: [
        Message.assistant("",
          tool_calls: [
            %{id: "call-one", name: "one", args: %{}},
            %{id: "call-two", name: "two", args: %{}}
          ]
        )
      ]
    }

    assert %{
             jump_to: :end,
             messages: [
               %Message{role: :tool, tool_call_id: "call-one"},
               %Message{role: :tool, tool_call_id: "call-two"},
               %Message{role: :assistant, content: content}
             ]
           } = ToolCallLimit.after_model(middleware, state, nil)

    assert content =~ "Tool call limit reached"
  end

  test "tool call limit end behavior rejects unrelated pending calls for scoped limits" do
    middleware = ToolCallLimit.new(tool_name: "limited", thread_limit: 0, exit_behavior: :end)

    state = %{
      messages: [
        Message.assistant("",
          tool_calls: [
            %{id: "call-limited", name: "limited", args: %{}},
            %{id: "call-open", name: "open", args: %{}}
          ]
        )
      ]
    }

    assert {:error, %Error{type: :tool_call_limit_parallel_end_unsupported}} =
             ToolCallLimit.after_model(middleware, state, nil)
  end

  test "summarization replaces older messages with an explicit summary model result" do
    assert {:ok, %{messages: messages}} =
             Agent.invoke(SummarizationAgent, %{
               messages: [
                 Message.user("one"),
                 Message.assistant("two"),
                 Message.user("three")
               ]
             })

    assert [
             %Message{role: :user, content: content},
             %Message{role: :user, content: "three"},
             _assistant
           ] =
             messages

    assert content =~ "Conversation summary:"
    assert content =~ "old summary"
  end

  test "summarization supports native trigger and keep policies with custom prompts" do
    parent = self()

    middleware =
      BeamWeaver.Agent.Middleware.Summarization.new(
        model: %ProfileSummaryModel{parent: parent},
        trigger: {:fraction, 0.8},
        keep: {:fraction, 0.5},
        token_counter: fn messages -> length(messages) * 200 end,
        summary_prompt: "Extract:\n{messages}"
      )

    state = %{
      messages: [
        Message.user("Message 1"),
        Message.assistant("Message 2"),
        Message.user("Message 3"),
        Message.assistant("Message 4")
      ]
    }

    assert %{messages: %BeamWeaver.Graph.Overwrite{value: rewritten}} =
             BeamWeaver.Agent.Middleware.Summarization.before_model(middleware, state, nil)

    assert [
             %Message{role: :user, content: "Conversation summary:\nprofile summary"},
             %Message{content: "Message 3"},
             %Message{content: "Message 4"}
           ] = rewritten

    assert_received {:summary_prompt, [%Message{role: :user, content: prompt}]}
    assert prompt =~ "Extract:"
    assert prompt =~ "Message 1"
    assert prompt =~ "Message 2"
  end

  test "summarization passes source metadata and formats history as message buffer text" do
    middleware =
      BeamWeaver.Agent.Middleware.Summarization.new(
        model: %CapturingSummaryModel{parent: self()},
        trigger: {:messages, 3},
        keep: {:messages, 1},
        summary_prompt: "Extract:\n{messages}"
      )

    messages = [
      Message.user("What is the weather in NYC?"),
      Message.assistant("I'll check.",
        tool_calls: [%ToolCall{id: "call_123", name: "get_weather", args: %{}}],
        response_metadata: %{large: String.duplicate("metadata ", 100)}
      ),
      Message.tool("72F and sunny", tool_call_id: "call_123"),
      Message.user("Thanks")
    ]

    assert %{messages: %BeamWeaver.Graph.Overwrite{value: rewritten}} =
             BeamWeaver.Agent.Middleware.Summarization.before_model(
               middleware,
               %{messages: messages},
               nil
             )

    assert [%Message{content: "Conversation summary:\ncaptured summary"} | _rest] = rewritten
    assert_received {:captured_summary_call, [%Message{role: :user, content: prompt}], opts}

    assert prompt =~ "Human: What is the weather in NYC?"
    assert prompt =~ "AI: I'll check."
    assert prompt =~ "Tool: 72F and sunny"
    refute prompt =~ "metadata metadata"
    assert Keyword.fetch!(opts, :metadata) == %{lc_source: "summarization"}
  end

  test "summarization can trigger from matching provider usage metadata" do
    middleware =
      BeamWeaver.Agent.Middleware.Summarization.new(
        model: %CapturingSummaryModel{
          parent: self(),
          profile: %BeamWeaver.Models.Profile{provider: :anthropic, max_input_tokens: 100_000}
        },
        trigger: {:tokens, 10_000},
        keep: {:messages, 1}
      )

    matching_messages = [
      Message.user("msg1"),
      Message.assistant("msg2",
        response_metadata: %{model_provider: :anthropic},
        usage_metadata: %{total_tokens: 10_001}
      )
    ]

    assert %{messages: %BeamWeaver.Graph.Overwrite{}} =
             BeamWeaver.Agent.Middleware.Summarization.before_model(
               middleware,
               %{messages: matching_messages},
               nil
             )

    mismatched_messages = [
      Message.user("msg1"),
      Message.assistant("msg2",
        response_metadata: %{model_provider: :openai},
        usage_metadata: %{total_tokens: 10_001}
      )
    ]

    assert %{} =
             BeamWeaver.Agent.Middleware.Summarization.before_model(
               middleware,
               %{messages: mismatched_messages},
               nil
             )

    bedrock_middleware =
      BeamWeaver.Agent.Middleware.Summarization.new(
        model: %CapturingSummaryModel{
          parent: self(),
          profile: %BeamWeaver.Models.Profile{
            provider: :amazon_bedrock,
            max_input_tokens: 100_000
          }
        },
        trigger: {:tokens, 10_000},
        keep: {:messages, 1}
      )

    assert %{messages: %BeamWeaver.Graph.Overwrite{}} =
             BeamWeaver.Agent.Middleware.Summarization.before_model(
               bedrock_middleware,
               %{
                 messages: [
                   Message.user("msg1"),
                   Message.assistant("msg2",
                     response_metadata: %{model_provider: "bedrock_converse"},
                     usage_metadata: %{total_tokens: 10_001}
                   )
                 ]
               },
               nil
             )
  end

  test "summarization token retention preserves assistant tool-call pairs" do
    middleware =
      BeamWeaver.Agent.Middleware.Summarization.new(
        model: %SummaryModel{},
        trigger: {:messages, 5},
        keep: {:messages, 2}
      )

    messages = [
      Message.user("initial"),
      Message.assistant("tooling",
        tool_calls: [
          %ToolCall{id: "call_1", name: "lookup", args: %{}},
          %ToolCall{id: "call_2", name: "lookup", args: %{}}
        ]
      ),
      Message.tool("result 1", tool_call_id: "call_1"),
      Message.tool("result 2", tool_call_id: "call_2"),
      Message.user("followup")
    ]

    assert %{messages: %BeamWeaver.Graph.Overwrite{value: rewritten}} =
             BeamWeaver.Agent.Middleware.Summarization.before_model(
               middleware,
               %{messages: messages},
               nil
             )

    assert [
             %Message{role: :user},
             %Message{role: :assistant, tool_calls: [%ToolCall{id: "call_1"}, %ToolCall{id: "call_2"}]},
             %Message{role: :tool, tool_call_id: "call_1"},
             %Message{role: :tool, tool_call_id: "call_2"},
             %Message{role: :user, content: "followup"}
           ] = rewritten
  end

  test "summarization validates context policies and can be disabled" do
    middleware =
      BeamWeaver.Agent.Middleware.Summarization.new(model: %SummaryModel{}, trigger: nil)

    assert %{} =
             BeamWeaver.Agent.Middleware.Summarization.before_model(
               middleware,
               %{messages: [Message.user("one"), Message.user("two")]},
               nil
             )

    assert_raise ArgumentError, ~r/fractional trigger values/, fn ->
      BeamWeaver.Agent.Middleware.Summarization.new(
        model: %ProfileSummaryModel{},
        trigger: {:fraction, 1.5}
      )
    end

    assert_raise ArgumentError, ~r/max_input_tokens/, fn ->
      BeamWeaver.Agent.Middleware.Summarization.new(
        model: %SummaryModel{},
        keep: {:fraction, 0.5}
      )
    end
  end

  test "tool emulator short-circuits selected tool calls through a model" do
    parent = self()

    tool =
      Tool.from_function!(
        name: "lookup",
        description: "Lookup facts",
        input_schema: %{"type" => "object"},
        handler: fn _input, _opts ->
          send(parent, :real_tool_executed)
          {:ok, "real"}
        end
      )

    middleware =
      ToolEmulator.new(
        tools: ["lookup"],
        model: %BeamWeaver.Models.FakeChatModel{
          parent: parent,
          response: Message.assistant("emulated lookup")
        }
      )

    request = %ToolCallRequest{
      tool_call: %{id: "call_1", name: "lookup", args: %{"query" => "beam"}},
      tool: tool
    }

    assert %Message{
             role: :tool,
             content: "emulated lookup",
             tool_call_id: "call_1",
             name: "lookup",
             metadata: %{emulated?: true}
           } = ToolEmulator.wrap_tool_call(middleware, request, fn _ -> Message.tool("real") end)

    refute_received :real_tool_executed
    assert_received {:fake_chat_model_call, [%Message{role: :user, content: prompt}], []}
    assert prompt =~ "Tool: lookup"
    assert prompt =~ "Lookup facts"
    assert prompt =~ "beam"
  end

  test "tool emulator lets non-selected tools execute normally and supports emulate-all" do
    parent = self()

    middleware =
      ToolEmulator.new(
        tools: ["lookup"],
        model: %BeamWeaver.Models.FakeChatModel{response: Message.assistant("unused")}
      )

    request = %ToolCallRequest{
      tool_call: %{id: "call_1", name: "calculator", args: %{"expression" => "2+2"}}
    }

    assert %Message{content: "real"} =
             ToolEmulator.wrap_tool_call(middleware, request, fn _request ->
               send(parent, :real_tool_executed)
               Message.tool("real", tool_call_id: "call_1", name: "calculator")
             end)

    assert_received :real_tool_executed

    emulate_all =
      ToolEmulator.new(model: %BeamWeaver.Models.FakeChatModel{response: Message.assistant("all")})

    assert %Message{content: "all", metadata: %{emulated?: true}} =
             ToolEmulator.wrap_tool_call(emulate_all, request, fn _request ->
               Message.tool("real", tool_call_id: "call_1", name: "calculator")
             end)
  end

  test "context editing keeps assistant/tool adjacency when trimming tool context" do
    # Upstream reference:
    # langchain/libs/langchain_v1/tests/unit_tests/agents/middleware/implementations/test_context_editing.py
    messages = [
      Message.user("start"),
      Message.assistant("", tool_calls: [%ToolCall{id: "call_old", name: "old_tool"}]),
      Message.tool("old result", tool_call_id: "call_old"),
      Message.assistant("", tool_calls: [%ToolCall{id: "call_new", name: "new_tool"}]),
      Message.tool("new result", tool_call_id: "call_new"),
      Message.assistant("final")
    ]

    edited = ContextEditing.keep_recent_tool_context(messages, 1)

    assert Enum.map(edited, & &1.role) == [:user, :assistant, :tool, :assistant]
    assert Enum.map(edited, & &1.content) == ["start", "", "new result", "final"]

    assert [%ToolCall{id: "call_new"}] =
             edited
             |> Enum.find(&match?(%Message{role: :assistant, content: ""}, &1))
             |> Map.fetch!(:tool_calls)
  end

  test "context editing clears old tool outputs in the model request without clearing excluded or recent tools" do
    parent = self()

    messages = [
      Message.user("start"),
      Message.assistant("",
        tool_calls: [%ToolCall{id: "call-old", name: "search", args: %{"query" => "old"}}]
      ),
      Message.tool("old result", tool_call_id: "call-old", name: "search", artifacts: [:old]),
      Message.assistant("",
        tool_calls: [%{id: "call-keep", name: "keep_tool", args: %{"query" => "keep"}}]
      ),
      Message.tool("keep result", tool_call_id: "call-keep", name: "keep_tool"),
      Message.assistant("",
        tool_calls: [%{id: "call-recent", name: "recent", args: %{"query" => "recent"}}]
      ),
      Message.tool("recent result", tool_call_id: "call-recent", name: "recent")
    ]

    assert {:ok, %{messages: final_messages}} =
             Agent.invoke(ContextEditingAgent, %{messages: messages}, context: %{parent: parent})

    assert_received {:model_call, model_messages, _opts}

    assert %Message{content: "[cleared]", artifacts: [], response_metadata: metadata} =
             Enum.find(model_messages, &match?(%Message{tool_call_id: "call-old"}, &1))

    assert metadata.context_editing == %{cleared: true, strategy: :clear_tool_uses}

    assert %Message{tool_calls: [%ToolCall{args: %{}}]} =
             Enum.find(model_messages, fn
               %Message{role: :assistant, tool_calls: [%ToolCall{id: "call-old"}]} -> true
               _message -> false
             end)

    assert %Message{content: "keep result"} =
             Enum.find(model_messages, &match?(%Message{tool_call_id: "call-keep"}, &1))

    assert %Message{content: "recent result"} =
             Enum.find(model_messages, &match?(%Message{tool_call_id: "call-recent"}, &1))

    assert Enum.find(final_messages, &match?(%Message{tool_call_id: "call-old"}, &1)).content ==
             "old result"
  end

  test "typed middleware decisions normalize to normal agent state updates" do
    parent = self()

    assert {:ok, %{messages: messages}} =
             Agent.invoke(DecisionAgent, %{messages: [Message.user("skip")]}, context: %{parent: parent})

    assert Enum.map(messages, & &1.content) == ["skip", "typed decision"]
    refute_received {:model_call, _messages, _opts}
  end

  test "input and output schemas validate agent boundaries" do
    assert {:error, %Error{type: :invalid_agent_input}} =
             Agent.invoke(SchemaAgent, %{text: "missing messages"})

    assert {:ok, %{messages: [_user, %Message{content: "schema ok"}]}} =
             Agent.invoke(SchemaAgent, %{messages: [Message.user("hello")]})
  end

  test "usage metadata is accumulated through a private agent channel" do
    assert {:ok, state} = Agent.invoke(UsageAgent, %{messages: [Message.user("hello")]})

    refute Map.has_key?(state, :usage)

    assert {:ok, %Message{content: "with usage"}} =
             FinalResponsePolicy.extract(:latest_assistant, state)
  end

  test "PII block prevents downstream model execution" do
    parent = self()

    assert {:error, %Error{type: :pii_detected}} =
             Agent.invoke(PIIAgent, %{messages: [Message.user("email me at ada@example.com")]},
               context: %{parent: parent}
             )

    refute_received {:model_call, _messages, _opts}
  end

  test "multiple PII middleware instances compose in an agent" do
    parent = self()

    assert {:ok, _state} =
             Agent.invoke(
               PIIMultipleAgent,
               %{messages: [Message.user("Contact test@example.com at 192.168.1.100")]},
               context: %{parent: parent}
             )

    assert_received {:model_call, [%Message{role: :user, content: content}], _opts}
    refute content =~ "test@example.com"
    refute content =~ "192.168.1.100"
    assert content =~ "[REDACTED_EMAIL]"
    assert content =~ "*.*.*.100"
  end

  test "PII edit mode handles Luhn cards, IP range validation, MAC separators, and URL forms" do
    # Upstream reference:
    # langchain/libs/langchain_v1/tests/unit_tests/agents/middleware/implementations/test_pii.py
    parent = self()

    assert {:ok, _state} =
             Agent.invoke(
               PIIEditAgent,
               %{
                 messages: [
                   Message.user(
                     "Email ada@example.com card 4532015112830366 invalid 1234567890123456 ip 192.168.1.1 bad 999.999.999.999 mac 00-1A-2B-3C-4D-5E url www.example.com and example.com/path"
                   )
                 ]
               },
               context: %{parent: parent}
             )

    assert_received {:model_call, [%Message{role: :user, content: content}], _opts}
    refute content =~ "ada@example.com"
    refute content =~ "4532015112830366"
    refute content =~ "192.168.1.1"
    refute content =~ "00-1A-2B-3C-4D-5E"
    refute content =~ "www.example.com"
    refute content =~ "example.com/path"
    assert content =~ "1234567890123456"
    assert content =~ "999.999.999.999"
  end

  defp tool_selection_request(opts) do
    tools = Keyword.fetch!(opts, :tools)

    %ModelRequest{
      model: Keyword.get(opts, :model, %RecordingModel{}),
      messages: Keyword.get(opts, :messages, [Message.user("find weather")]),
      tools: tools,
      tool_set: BeamWeaver.Agent.ToolSet.new(tools),
      state: %{},
      runtime: %{context: %{}},
      model_opts: []
    }
  end

  defp selection_tool(name) do
    Tool.from_function!(
      name: name,
      description: "#{name} tool",
      input_schema: %{"type" => "object"},
      handler: fn input, _opts -> {:ok, input} end
    )
  end
end
