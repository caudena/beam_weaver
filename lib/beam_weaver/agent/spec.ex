defmodule BeamWeaver.Agent.Spec do
  @moduledoc """
  Normalized declaration data for a BeamWeaver agent module.

  The public DSL compiles into this struct first; graph construction then reads
  plain data instead of reaching back into module attributes.
  """

  defstruct [
    :module,
    :name,
    :description,
    :model,
    :context_schema,
    :input_schema,
    :output_schema,
    :response_format,
    :checkpointer,
    :store,
    :cache,
    :debug,
    :recursion_limit,
    :execution_mode,
    :filesystem,
    :filesystem_permissions,
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
    model_opts: [],
    validate_tools: false,
    tools: [],
    middleware: [],
    system_prompt: nil,
    interrupt_before: [],
    interrupt_after: []
  ]

  @type t :: %__MODULE__{
          module: module(),
          name: atom() | String.t() | nil,
          description: String.t() | nil,
          model: term(),
          model_opts: keyword(),
          tools: [term()],
          middleware: [term()],
          system_prompt: term(),
          context_schema: map() | nil,
          input_schema: map() | nil,
          output_schema: map() | nil,
          response_format: term(),
          checkpointer: term(),
          store: term(),
          cache: term(),
          filesystem: term(),
          filesystem_permissions: term(),
          skills: term(),
          memory: term(),
          subagents: term(),
          async_subagents: term(),
          compact_conversation: term(),
          overflow_recovery: term(),
          prompt_caching: term(),
          exclude_tools: term(),
          tool_descriptions: term(),
          interrupt_on: term(),
          validate_tools: boolean(),
          interrupt_before: list() | :all,
          interrupt_after: list() | :all,
          debug: boolean() | nil,
          execution_mode: atom() | nil,
          recursion_limit: non_neg_integer() | nil
        }

  @dsl_attrs [
    :name,
    :description,
    :model,
    :model_opts,
    :tools,
    :validate_tools,
    :middleware,
    :filesystem,
    :filesystem_permissions,
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
    :system_prompt,
    :response_format,
    :checkpointer,
    :store,
    :cache,
    :context_schema,
    :input_schema,
    :output_schema,
    :interrupt_before,
    :interrupt_after,
    :debug,
    :recursion_limit,
    :execution_mode
  ]

  @default_attrs %{
    model_opts: [],
    validate_tools: false,
    debug: false
  }

  @list_attrs [:tools, :middleware, :interrupt_before, :interrupt_after]

  @doc false
  @spec from_dsl_attrs(module(), map()) :: t()
  def from_dsl_attrs(module, attrs) when is_atom(module) and is_map(attrs) do
    attrs
    |> Map.take(@dsl_attrs)
    |> apply_defaults()
    |> normalize_list_attrs()
    |> Map.put(:module, module)
    |> put_default_name(module)
    |> then(&struct(__MODULE__, &1))
  end

  defp apply_defaults(attrs) do
    Enum.reduce(@default_attrs, attrs, fn {key, default}, acc ->
      Map.update(acc, key, default, &(&1 || default))
    end)
  end

  defp normalize_list_attrs(attrs) do
    Enum.reduce(@list_attrs, attrs, fn key, acc ->
      Map.update(acc, key, [], &List.wrap(&1 || []))
    end)
  end

  defp put_default_name(attrs, module), do: Map.update(attrs, :name, inspect(module), &(&1 || inspect(module)))
end
