defmodule BeamWeaver.Agent.Subagent.Spec do
  @moduledoc """
  A subagent described by options, for the `subagents` declaration.

  `name` and `description` tell the parent's model what the subagent is for.
  The other options describe the agent that runs, with the names of the
  `BeamWeaver.Agent.build/1` options: `system_prompt`, `model`, `model_opts`,
  `tools`, `middleware`, `response_format`, `context_schema`, `filesystem`,
  `skills`, `memory`, `subagents`, `compact_conversation`, `interrupt_on`,
  `checkpointer`, `recursion_limit` and the rest, except that file rules are
  `permissions`.

  A subagent without `model` or `tools` uses the parent's, and one without
  `interrupt_on` uses the parent's review rules; pass `interrupt_on: false`
  to turn review off. These options are particular to subagents:

    * `capture_output` - keep the answer in the parent's `subagent_outputs`.
    * `execution_mode` - `:agent_loop` (default), `:structured_once` or
      `:research_then_generate`.
    * `inherit_messages` - start from the parent's conversation.
    * `base_middleware` - capabilities built from the parent's settings:
      `BeamWeaver.Agent.Middleware.Filesystem`,
      `BeamWeaver.Agent.Middleware.Skills`,
      `BeamWeaver.Agent.Middleware.TodoList`, or `:deepagents` for the
      general-purpose subagent's set: file tools, skills, and the parent's
      summarization and `compact_conversation` settings, without a task
      list.

  `from_agent_module/2` reads every declaration of an agent module, so the
  subagent runs as the module declares it. Agent modules may name each other,
  or themselves, as subagents: a `subagent` line that leads back to a module
  being read is read when that subagent is built. The parent checks each spec
  when it is built and builds it when a `task` call runs it. See
  [Subagents](subagents.md).
  """

  @agent_fields [
    :system_prompt,
    :model,
    :model_opts,
    :tools,
    :validate_tools,
    :middleware,
    :response_format,
    :context_schema,
    :input_schema,
    :output_schema,
    :filesystem,
    :permissions,
    :skills,
    :memory,
    :subagents,
    :async_subagents,
    :compact_conversation,
    :overflow_recovery,
    :prompt_caching,
    :exclude_tools,
    :tool_descriptions,
    :interrupt_on,
    :interrupt_before,
    :interrupt_after,
    :checkpointer,
    :store,
    :cache,
    :recursion_limit,
    :tool_timeout,
    :step_timeout,
    :run_timeout,
    :capability_profile
  ]

  # `source` is the agent module a spec reads, with the options given for it,
  # and `read?` says whether its declarations were read; neither is an option.
  @private_fields [:source, :read?]

  defstruct [
    :name,
    :description,
    :system_prompt,
    :model,
    :tools,
    :validate_tools,
    :response_format,
    :context_schema,
    :input_schema,
    :output_schema,
    :filesystem,
    :permissions,
    :skills,
    :memory,
    :subagents,
    :async_subagents,
    :compact_conversation,
    :overflow_recovery,
    :prompt_caching,
    :exclude_tools,
    :tool_descriptions,
    :interrupt_on,
    :checkpointer,
    :store,
    :cache,
    :recursion_limit,
    :tool_timeout,
    :step_timeout,
    :run_timeout,
    :capability_profile,
    :capture_output,
    :source,
    model_opts: [],
    middleware: [],
    interrupt_before: [],
    interrupt_after: [],
    execution_mode: :agent_loop,
    base_middleware: [],
    inherit_messages: false,
    read?: true
  ]

  @type t :: %__MODULE__{}

  @doc """
  Builds a spec from options. Raises `ArgumentError` for an unknown option or
  a string key.
  """
  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    case cast(opts) do
      {:ok, spec} -> spec
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc false
  # `new/1` that returns the problem instead of raising it.
  @spec cast(term()) :: {:ok, t()} | {:error, String.t()}
  def cast(%__MODULE__{} = spec), do: {:ok, spec}

  def cast(opts) when is_map(opts) and not is_struct(opts) do
    with :ok <- check_keys(opts), do: {:ok, struct(__MODULE__, opts)}
  end

  def cast(opts) when is_list(opts) do
    if Enum.all?(opts, &match?({_key, _value}, &1)),
      do: cast(Map.new(opts)),
      else: {:error, "subagent spec options must be a keyword list or a map, got #{inspect(opts)}"}
  end

  def cast(other), do: {:error, "subagent spec options must be a keyword list or a map, got #{inspect(other)}"}

  @doc """
  Builds a spec from an agent module's declarations, as the `subagent` line of
  a `subagents` block does. `opts` replace what the module declares.
  """
  @spec from_agent_module(module(), keyword() | map()) :: t()
  def from_agent_module(module, opts \\ []) when is_atom(module) do
    Code.ensure_compiled!(module)

    unless function_exported?(module, :__beam_weaver_agent_spec__, 0) do
      raise ArgumentError, "#{inspect(module)} is not a BeamWeaver agent module"
    end

    overrides = opts |> Map.new() |> validate_keys!()

    if module in reading(),
      do: %__MODULE__{source: {module, overrides}, read?: false},
      else: read_module(module, overrides)
  end

  @doc false
  # Reads the declarations of a spec that `from_agent_module/2` left unread,
  # as it does for the `subagent` lines of the module it reads.
  @spec read(t()) :: t()
  def read(%__MODULE__{read?: false, source: {module, overrides}}), do: read_module(module, overrides)
  def read(%__MODULE__{} = spec), do: spec

  defp read_module(module, overrides) do
    agent = reading(module, fn -> module.__beam_weaver_agent_spec__() end)

    if is_nil(agent.model) do
      raise ArgumentError,
            "#{inspect(module)} has no model; run a graph module as a %BeamWeaver.Agent.Subagent.Compiled{} subagent"
    end

    fields =
      agent
      |> Map.from_struct()
      |> Map.put(:permissions, agent.filesystem_permissions)
      |> Map.take([:name, :description, :execution_mode | @agent_fields])
      |> Map.update!(:tools, &if(&1 == [], do: nil, else: &1))
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.merge(overrides)
      |> Map.put(:source, {module, overrides})

    struct(__MODULE__, fields)
  end

  # Reading a module's declarations evaluates its `subagent` lines, which
  # read those modules in turn, so agents that name each other, or
  # themselves, would be read forever. A spec for a module that is being read
  # only remembers the module, until `read/1`.
  @reading {__MODULE__, :reading}

  defp reading, do: Process.get(@reading, [])

  defp reading(module, fun) do
    modules = reading()
    Process.put(@reading, [module | modules])

    try do
      fun.()
    after
      if modules == [], do: Process.delete(@reading), else: Process.put(@reading, modules)
    end
  end

  @doc false
  # The options this spec gives `BeamWeaver.Agent.build/1`, with the file
  # rules under their build name.
  def agent_options(%__MODULE__{} = spec) do
    spec
    |> Map.take(@agent_fields)
    |> Map.delete(:permissions)
    |> Map.put(:filesystem_permissions, spec.permissions)
  end

  defp validate_keys!(opts) do
    case check_keys(opts) do
      :ok -> opts
      {:error, message} -> raise ArgumentError, message
    end
  end

  defp check_keys(opts) do
    Enum.find_value(opts, :ok, fn
      {key, _value} when is_binary(key) ->
        {:error, "subagent spec options must use atom keys, got #{inspect(key)}"}

      {key, _value} ->
        unless key in option_names() do
          {:error, "unknown subagent option #{inspect(key)}; expected one of #{inspect(option_names())}"}
        end
    end)
  end

  defp option_names,
    do: %__MODULE__{} |> Map.from_struct() |> Map.drop(@private_fields) |> Map.keys() |> Enum.sort()
end
