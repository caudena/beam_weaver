defmodule BeamWeaver.Agent do
  @moduledoc ~S"""
  Declare an agent whose model selects tools and produces an answer.

  An agent module is a reusable definition. Each invocation evaluates its
  declarations, builds the loop with current options and returns completed
  state, an interrupt or an error. Configure the provider in your application
  as described in [Installation](installation.md).

  ```elixir
  defmodule MyApp.OrderLookup do
    use BeamWeaver.Tool
    name "order_lookup"
    description "Read the sample order's delivery day."
    schema do
      field :order_id, :string
    end
    @impl true
    def invoke(_tool, %{"order_id" => "A-1001"}, _opts), do: {:ok, "Thursday"}
    def invoke(_tool, _input, _opts), do: {:error, "Order not found"}
  end

  defmodule MyApp.SupportAgent do
    use BeamWeaver.Agent
    model "openai:gpt-5.4-mini", max_tokens: 256, timeout: 60_000
    system_prompt "Call order_lookup for order questions and use its result."
    tools [MyApp.OrderLookup]
    recursion_limit 10
  end

  {:ok, state} = MyApp.SupportAgent.invoke(%{messages: ["When does A-1001 arrive?"]})
  tool_result = Enum.find(state.messages, &(&1.role == :tool and &1.name == "order_lookup"))
  "Thursday" = BeamWeaver.Core.Message.text(tool_result)
  true = state.messages |> List.last() |> BeamWeaver.Core.Message.text() |> String.contains?("Thursday")
  ```

  ## Module and runtime interfaces

  `use BeamWeaver.Agent` supplies `invoke/2`, `stream_events/2`, `resume/2`,
  `resume_review/2`, `get_state/1` and `compiled_graph/1`. The functions in this
  module accept the agent module or a `BeamWeaver.Agent.Built` value first.
  Use `build/1` for definitions assembled from runtime data and `declarations/1`
  to derive build options from a module.

  ## Declaration lifecycle

  Model, prompt, tools, middleware and storage expressions are evaluated per
  invocation. Tool/schema module declarations are compiled contracts instead.
  ETS tables and processes need owners that outlive the calls using them:
  create them under supervision or in the caller and pass existing values.
  Direct ETS construction in a repeated storage declaration is rejected.
  Database adapter structs refer to an independently supervised repository.

  Per-call context is not persisted. Supply current context on every invocation
  and resume. Reuse the checkpointer and thread ID to continue conversation state.

  ## Results and capabilities

  `{:ok, state}` means the run completed, not necessarily that every requested
  business action succeeded. Inspect tool outcomes or `structured_response`.
  `{:interrupted, interrupt}` requires review/input; `{:error, error}` exposes
  an execution failure.

  The [Agent DSL guide](agents.md) organizes every declaration by concern and
  explains call overrides. [Tools](tools.md), [Structured Output](structured_output.md),
  [Middleware](middleware.md) and [Deep Agents](deep_agents.md) cover composition.
  An agent also implements the graph behavior and can run as a subgraph.
  """

  alias BeamWeaver.Agent.Built
  alias BeamWeaver.Agent.DSL
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Compiled

  @typedoc "Initial state or new thread input; messages accept strings and Message values."
  @type input :: map()
  @typedoc "A module defined with use BeamWeaver.Agent."
  @type agent_module :: module()
  @typedoc "A validated runtime definition returned by build/1."
  @type built_agent :: Built.t()

  @doc false
  @callback __beam_weaver_agent_spec__() :: struct()

  defmacro __using__(_opts) do
    BeamWeaver.Agent.Use.quoted()
  end

  @doc false
  defmacro graph(_block), do: DSL.graph_declaration!(__CALLER__, :graph)
  @doc false
  defmacro node(_name, _fun, _opts \\ []), do: DSL.graph_declaration!(__CALLER__, :node)
  @doc false
  defmacro edge(_start_node, _end_node, _opts \\ []), do: DSL.graph_declaration!(__CALLER__, :edge)
  @doc false
  defmacro reducer(_key, _reducer), do: DSL.graph_declaration!(__CALLER__, :reducer)

  @doc "Declares the model and constructor options, evaluated on each invocation. See [Models](models.md)."
  defmacro model(expr_ast, opts_ast \\ nil) do
    quote bind_quoted: [expr_ast: Macro.escape(expr_ast), opts_ast: Macro.escape(opts_ast)] do
      @beam_weaver_model expr_ast
      @beam_weaver_model_options opts_ast
    end
  end

  @declaration_docs %{
    name: "Sets the agent name used in traces and delegation. Defaults to the module name.",
    description: "Describes the agent to a parent deciding whether to delegate a task.",
    model_opts: "Sets model options that override options following the model declaration.",
    validate_tools: "Enables schema validation before tool execution; invalid arguments are returned to the model.",
    filesystem: "Adds filesystem middleware and tools using the supplied backend. See [Filesystem](filesystem.md).",
    filesystem_permissions:
      "Sets ordered path permissions for filesystem tools. See [Filesystem](filesystem.md#permissions).",
    skills: "Sets directories from which the agent discovers skills. See [Skills](skills.md).",
    memory: "Sets memory files to load into the agent instructions. See [Memory Files](memory_files.md).",
    compact_conversation:
      "Configures history summarization and the compact_conversation tool. See [Context Management](context_management.md).",
    overflow_recovery:
      "Configures recovery when a provider rejects an oversized context. See [Context Management](context_management.md).",
    prompt_caching: "Configures supported provider prompt caching. See [Caching](caching.md).",
    exclude_tools: "Hides the named tools, including tools supplied by capabilities.",
    tool_descriptions: "Overrides model-visible descriptions by tool name.",
    interrupt_on: "Configures human review before named tool calls. See [Human-in-the-Loop](human_in_the_loop.md).",
    system_prompt: "Sets instructions sent before the conversation on every model call.",
    checkpointer:
      "Sets default checkpoint storage. The resource must outlive a call; do not construct ETS storage in the declaration.",
    store: "Sets default long-term memory storage. The resource must outlive a call.",
    cache: "Sets default cache storage. The resource must outlive a call.",
    input_schema: "Sets the input state schema. See [Agents](agents.md) for validation and key filtering.",
    output_schema: "Sets the final state schema. Structured model answers use response_schema/2 instead.",
    interrupt_before: "Pauses before the named graph steps. Resume using resume/3.",
    interrupt_after: "Pauses after the named graph steps. Resume using resume/3.",
    recursion_limit: "Limits the number of graph supersteps in a run; this is not a token limit.",
    execution_mode:
      "Sets subagent execution mode: agent_loop, structured_once or research_then_generate. See [Subagents](subagents.md#execution-modes).",
    capability_profile: "Selects per-model capability defaults. See [Capability Profiles](profiles.md).",
    tool_timeout: "Sets the timeout for each tool invocation, in milliseconds.",
    step_timeout: "Sets the timeout for a graph step, in milliseconds.",
    run_timeout: "Sets the timeout for the complete run, in milliseconds."
  }

  for {macro_name, attr} <- DSL.simple_macro_fields() do
    @doc Map.fetch!(@declaration_docs, macro_name)
    defmacro unquote(macro_name)(expr_ast) do
      attr = unquote(attr)

      quote bind_quoted: [attr: attr, expr_ast: Macro.escape(expr_ast)] do
        Module.put_attribute(__MODULE__, attr, expr_ast)
      end
    end
  end

  for macro_name <- [:tools, :middleware, :subagents, :async_subagents], attr = :"beam_weaver_#{macro_name}" do
    @doc "Declares #{macro_name} as a list or a block; entries are evaluated on each invocation. See [Agents](agents.md)."
    defmacro unquote(macro_name)(do: block) do
      ast = DSL.block_ast!(__CALLER__, unquote(macro_name), block)
      attr = unquote(attr)

      quote bind_quoted: [attr: attr, ast: Macro.escape(ast)] do
        Module.put_attribute(__MODULE__, attr, ast)
      end
    end

    defmacro unquote(macro_name)(expr_ast) do
      attr = unquote(attr)

      quote bind_quoted: [attr: attr, expr_ast: Macro.escape(expr_ast)] do
        Module.put_attribute(__MODULE__, attr, expr_ast)
      end
    end
  end

  @doc "Declares a final answer schema with automatic, provider or tool strategy. See [Structured Output](structured_output.md)."
  defmacro response_schema(schema_ast, opts_ast \\ []) do
    response_ast =
      quote do
        BeamWeaver.Agent.__response_schema__(
          unquote(schema_ast),
          unquote(opts_ast)
        )
      end

    quote do
      @beam_weaver_response_format unquote(Macro.escape(response_ast))
    end
  end

  @doc "Sets an explicit structured-output strategy."
  defmacro response_format(expr_ast) do
    quote bind_quoted: [expr_ast: Macro.escape(expr_ast)] do
      @beam_weaver_response_format expr_ast
    end
  end

  @doc "Declares the validated per-call context fields. See [Runtime Context](runtime_context.md)."
  defmacro context_schema(do: block) do
    entry_quotes =
      __CALLER__
      |> DSL.schema_block_entries!(block)
      |> Enum.map(fn entry ->
        quote do
          @beam_weaver_context_schema_entries unquote(Macro.escape(entry))
        end
      end)

    quote do
      (unquote_splicing(entry_quotes))
    end
  end

  defmacro context_schema(expr_ast) do
    quote bind_quoted: [expr_ast: Macro.escape(expr_ast)] do
      @beam_weaver_context_schema expr_ast
    end
  end

  @doc "Declares graph step breakpoints with before: and after: lists."
  defmacro interrupts(opts_ast) do
    quote do
      require BeamWeaver.Graph.DSL
      BeamWeaver.Graph.DSL.interrupts(unquote(opts_ast))
    end
  end

  @doc "Declares a field inside a context_schema block. Required fields use required: true."
  defmacro field(_name, _type, _opts \\ []),
    do: DSL.compile_error!(__CALLER__, "field/2 can only be used inside context_schema blocks")

  defmacro __before_compile__(env) do
    BeamWeaver.Agent.BeforeCompile.compile(env)
  end

  def __response_schema__(schema, opts) do
    opts = List.wrap(opts)

    schema =
      schema
      |> response_json_schema()
      |> put_schema_text("title", Keyword.get(opts, :name))
      |> put_schema_text("description", Keyword.get(opts, :description))

    case Keyword.get(opts, :strategy, :auto) do
      :auto -> BeamWeaver.Agent.StructuredOutput.auto(schema, opts)
      :tool -> BeamWeaver.Agent.StructuredOutput.tool(schema, opts)
      :provider -> BeamWeaver.Agent.StructuredOutput.provider(schema, opts)
      other -> raise ArgumentError, "unknown response_schema strategy #{inspect(other)}"
    end
  end

  # A module must declare its schema: one that declares none, or doesn't
  # exist, would ask the model for an empty object.
  defp response_json_schema(schema) when is_atom(schema) do
    if String.starts_with?(Atom.to_string(schema), "Elixir.") and is_nil(BeamWeaver.Schema.module_schema(schema)) do
      raise ArgumentError,
            "response_schema #{inspect(schema)} is not a schema module: `use BeamWeaver.Schema` in it, or define `json_schema/0`"
    end

    BeamWeaver.Schema.to_json_schema(schema)
  end

  defp response_json_schema(schema), do: BeamWeaver.Schema.to_json_schema(schema)

  defp put_schema_text(schema, _key, nil), do: schema
  defp put_schema_text(schema, key, text) when is_map(schema), do: Map.put(schema, key, to_string(text))

  @doc """
  Builds an agent at runtime, from options with the same names as the
  declarations: `:model`, `:system_prompt`, `:tools`, `:middleware`,
  `:response_format`, `:checkpointer`, `:store` and so on. An option that
  isn't one of them is an `:invalid_agent` error that names it.

  Each subagent is checked as a `task` call would build it, without building
  it: one that can't be built, for example with a tool that isn't one or a
  model that can't be resolved, is an `:invalid_subagent` error that names
  it. An agent module checks its subagents the same way on its first call.

  Run the result with `invoke/3`, which takes the same call options as for an
  agent module: a call's `:checkpointer`, `:store` and `:cache` replace the
  ones given here. Prefer agent modules for agents your application defines
  in code. See [Agents built at runtime](agents.md#agents-built-at-runtime).
  """
  @spec build(keyword() | map()) :: {:ok, Built.t()} | {:error, Error.t()}
  defdelegate build(opts), to: BeamWeaver.Agent.Builder

  @doc """
  Returns an agent module's declarations as a map with the option names of
  `build/1`: `:model`, `:model_opts`, `:system_prompt`, `:tools` and the rest.
  An option the module doesn't declare holds its default. The declarations
  are evaluated when this is called, as on each invocation.

  Change one and pass the map to `build/1` to build the same agent with other
  instructions or another model:

      defmodule MyApp.BaseAgent do
        use BeamWeaver.Agent
        model "openai:gpt-5.4-mini", max_tokens: 128, timeout: 60_000
        system_prompt "Reply briefly."
      end

      declared = BeamWeaver.Agent.declarations(MyApp.BaseAgent)
      {:ok, agent} = BeamWeaver.Agent.build(%{declared | system_prompt: "Reply in French."})
      {:ok, result} = BeamWeaver.Agent.invoke(agent, %{messages: ["Say hello."]})
      answer = result.messages |> List.last() |> BeamWeaver.Core.Message.text()
      true = String.contains?(String.downcase(answer), "bonjour")

  It also works in a module attribute, such as
  `@model BeamWeaver.Agent.declarations(MyApp.BaseAgent).model`, while the
  agent module compiles in the same project.

  `execution_mode`, which only applies when the module runs as a subagent,
  isn't among them. Raises `ArgumentError` for a module that isn't an agent
  module.
  """
  @spec declarations(agent_module()) :: map()
  defdelegate declarations(agent_module), to: BeamWeaver.Agent.Builder

  @doc """
  Runs an agent until the model answers.

  `agent` is an agent module or a built agent; `input` is the starting state,
  such as `%{messages: ["Where is my order?"]}`. Returns `{:ok, state}`,
  `{:interrupted, interrupt}` when the run pauses, or `{:error, error}`.

  Options:

    * `:checkpointer` and `:config` - save the thread named by
      `%{"configurable" => %{"thread_id" => id}}`, to continue it later.
    * `:context` - per-call data for tools and middleware.
    * `:store` - the memory store for long-term memory.
    * `:recursion_limit` - the most steps this run may take.
    * `:step_timeout`, `:run_timeout` - time limits for one step and for this
      run, in milliseconds.
    * `:trace` - a name and fields for this run's trace.
    * `:model_opts` - extra model options for this run.
  """
  @spec invoke(agent_module() | built_agent(), input(), keyword()) ::
          {:ok, map()} | {:interrupted, map()} | {:error, Error.t()}
  defdelegate invoke(agent, input, opts \\ []), to: BeamWeaver.Agent.Runner

  @doc """
  Runs an agent and returns its events as `BeamWeaver.Stream.Envelope` structs:
  tokens, tool calls, state updates and the final message.

  Pass `live: true` to receive events while the run progresses; without it the
  same events come back as a list when the run ends. `stream_mode:` keeps only
  some channels, such as `[:messages, :tools]`. Takes the options of
  `invoke/3`. See [Streaming](streaming.md).
  """
  @spec stream_events(agent_module() | built_agent(), input(), keyword()) ::
          {:ok, Enumerable.t()} | {:interrupted, map()} | {:error, Error.t()}
  defdelegate stream_events(agent, input, opts \\ []), to: BeamWeaver.Agent.Runner

  @doc """
  Continues a paused thread with a resume value. Pass the checkpointer, config
  and context of the call that paused. With `nil`, it also continues a run
  that a breakpoint (`interrupt_before`, `interrupt_after`) or a crash stopped.
  """
  @spec resume(agent_module() | built_agent(), term(), keyword()) ::
          {:ok, map()} | {:interrupted, map()} | {:error, Error.t()}
  defdelegate resume(agent, resume, opts \\ []), to: BeamWeaver.Agent.Runner

  @doc """
  Continues a thread paused by `interrupt_on` with review decisions, such as
  `[BeamWeaver.Agent.HITL.decision(:approve)]`. See
  [Human-in-the-Loop](human_in_the_loop.md).
  """
  @spec resume_review(agent_module() | built_agent(), term(), keyword()) ::
          {:ok, map()} | {:interrupted, map()} | {:error, Error.t()}
  defdelegate resume_review(agent, review_or_decisions, opts \\ []),
    to: BeamWeaver.Agent.Runner

  @doc """
  Reads the latest saved snapshot of the thread in `opts[:config]`:
  `{:ok, snapshot}`, or `:error` when the thread has no checkpoint.
  """
  @spec get_state(agent_module() | built_agent(), keyword()) :: {:ok, map()} | :error | {:error, Error.t()}
  defdelegate get_state(agent, opts \\ []), to: BeamWeaver.Agent.Runner

  @doc """
  Compiles an agent module's graph, for example to use the agent as a subgraph.
  The module's own `c:BeamWeaver.Graph.compiled_graph/1` calls it.
  """
  @spec compiled_graph(agent_module(), keyword()) :: {:ok, Compiled.t()} | {:error, Error.t()}
  defdelegate compiled_graph(agent_module, opts \\ []), to: BeamWeaver.Agent.Runner

  @jump_destinations [:end, :model, :tools]

  @doc """
  Returns a `BeamWeaver.Graph.Command` that applies `update`, then jumps to
  `destination`, as `{:jump, destination, update}` does from a state hook.
  `destination` is `:end`, `:model` or `:tools`; anything else raises
  `ArgumentError`.

    * A tool returns it, or a `wrap_tool_call` wrapper returns it as its
      result: `:end` ends the run once the round's tool calls have run, and
      `:model` sends their results to the model, also from a tool that
      returns directly. The update's messages answer the tool call, as with
      any command a tool returns.
    * A `wrap_model_call` wrapper returns it as the `command` of a
      `BeamWeaver.Agent.ExtendedModelResponse`: the jump follows the
      model's reply.

  ```elixir
  defmodule MyApp.CloseTicket do
    use BeamWeaver.Tool

    name "close_ticket"
    description "Close a support ticket. The conversation ends with it."

    schema do
      field :ticket_id, :string
    end

    @impl true
    def invoke(_tool, %{"ticket_id" => id}, _opts) do
      message = BeamWeaver.Core.Message.tool("Ticket \#{id} closed.")
      {:ok, BeamWeaver.Agent.jump(:end, %{messages: [message]})}
    end
  end
  ```

  See [What hooks return](middleware.md#what-hooks-return).
  """
  @spec jump(:end | :model | :tools, map()) :: Command.t()
  def jump(destination, update \\ %{})

  def jump(destination, update) when destination in @jump_destinations and is_map(update) and not is_struct(update),
    do: %Command{update: Map.put(update, :jump_to, destination)}

  def jump(destination, update) when destination in @jump_destinations,
    do: raise(ArgumentError, "jump update must be a map, got: #{inspect(update)}")

  def jump(destination, _update),
    do: raise(ArgumentError, "jump destination must be :end, :model or :tools, got: #{inspect(destination)}")
end
