defmodule BeamWeaver.Agent do
  @moduledoc ~S"""
  Agent modules: a chat model, instructions and tools that run in a loop until
  the model answers.

  ```elixir
  defmodule MyApp.Tools.LookupOrder do
    use BeamWeaver.Tool

    name "lookup_order"
    description "Look up the shipping status of an order by its id."

    schema do
      field :order_id, :string
    end

    @impl true
    def invoke(_tool, %{"order_id" => order_id}, _opts), do: {:ok, "Order #{order_id} shipped on Monday."}
  end

  defmodule MyApp.SupportAgent do
    use BeamWeaver.Agent

    alias BeamWeaver.Models.FakeChatModel

    model "fake:chat",
      responses: [
        FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1001"}),
        "Your order A-1001 shipped on Monday."
      ]

    system_prompt "You are Acme's support agent."
    tools [MyApp.Tools.LookupOrder]
  end

  {:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Where is my order A-1001?"]})
  result.messages |> List.last() |> BeamWeaver.Core.Message.text()
  #=> "Your order A-1001 shipped on Monday."
  ```

  `use BeamWeaver.Agent` gives the module `invoke/2`, `stream_events/2`,
  `resume/2`, `resume_review/2` and `get_state/1`, which call the functions
  of the same name in this module.

  ## Declarations

  | Declaration | What it does |
  | --- | --- |
  | `model "provider:model", opts` | The chat model and its options. |
  | `system_prompt "..."` | Instructions sent ahead of the conversation. |
  | `tools [...]`, or `tools do tool Mod end` | Tools the model may call. |
  | `middleware [...]`, or `middleware do use Mod, opts end` | Code around model and tool calls. |
  | `response_schema Schema, opts` | A structured final answer, in `structured_response`. |
  | `context_schema do field ... end` | The fields of the per-call `context:`. |
  | `interrupt_on %{"tool_name" => true}` | Pauses before those tools for human review. |
  | `recursion_limit 50` | The most steps one run may take. |
  | `tool_timeout`, `step_timeout`, `run_timeout` | Time limits, in milliseconds, for each tool call, each step and the whole run. |
  | `name "..."`, `description "..."` | The agent's name and what it does. |
  | `filesystem`, `skills`, `memory`, `subagents`, `async_subagents` | Deep agent capabilities. |
  | `compact_conversation`, `overflow_recovery`, `prompt_caching` | Context and cost management. |
  | `capability_profile :auto` | Applies the capability profile of the agent's model. |

  Declarations, including the options after `model "..."`, are evaluated each
  time the agent runs, so they can read your configuration. For the same
  reason, storage you declare must outlive the call: a module that creates an
  ETS saver, store or cache in a declaration, such as
  `checkpointer BeamWeaver.Checkpoint.ETS.new()`, doesn't compile, because
  every call would get a new, empty one. Create it once and pass it per call
  with `checkpointer:`, `store:` or `cache:`, or declare storage kept in your
  database, such as `BeamWeaver.Checkpoint.Ecto`.

  Every agent module declares a model. A module that runs a graph of your own
  nodes instead is a graph module, with `use BeamWeaver.Graph`. An agent
  module implements the `BeamWeaver.Graph` behaviour too, so it runs as a
  node of a graph, and its `c:BeamWeaver.Graph.compiled_graph/1` compiles
  the agent loop.

  The [Agents](agents.md) guide covers each declaration, and
  [Deep Agents](deep_agents.md) covers the capabilities.
  """

  alias BeamWeaver.Agent.Built
  alias BeamWeaver.Agent.DSL
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Compiled

  @type input :: map()
  @type agent_module :: module()
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

  defmacro model(expr_ast, opts_ast \\ nil) do
    quote bind_quoted: [expr_ast: Macro.escape(expr_ast), opts_ast: Macro.escape(opts_ast)] do
      @beam_weaver_model expr_ast
      @beam_weaver_model_options opts_ast
    end
  end

  for {macro_name, attr} <- DSL.simple_macro_fields() do
    defmacro unquote(macro_name)(expr_ast) do
      attr = unquote(attr)

      quote bind_quoted: [attr: attr, expr_ast: Macro.escape(expr_ast)] do
        Module.put_attribute(__MODULE__, attr, expr_ast)
      end
    end
  end

  for macro_name <- [:tools, :middleware, :subagents, :async_subagents], attr = :"beam_weaver_#{macro_name}" do
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

  defmacro response_format(expr_ast) do
    quote bind_quoted: [expr_ast: Macro.escape(expr_ast)] do
      @beam_weaver_response_format expr_ast
    end
  end

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

  defmacro interrupts(opts_ast) do
    quote do
      require BeamWeaver.Graph.DSL
      BeamWeaver.Graph.DSL.interrupts(unquote(opts_ast))
    end
  end

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
end
