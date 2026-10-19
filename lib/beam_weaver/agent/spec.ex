defmodule BeamWeaver.Agent.Spec do
  @moduledoc false

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
    :capability_profile,
    :tool_timeout,
    :step_timeout,
    :run_timeout,
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
          capability_profile: term(),
          tool_timeout: timeout() | nil,
          step_timeout: timeout() | nil,
          run_timeout: timeout() | nil,
          validate_tools: boolean(),
          interrupt_before: list() | :all,
          interrupt_after: list() | :all,
          execution_mode: atom() | nil,
          recursion_limit: non_neg_integer() | nil
        }

  @spec from_dsl_attrs(module(), map()) :: t()
  def from_dsl_attrs(module, attrs) when is_atom(module) and is_map(attrs) do
    struct(
      __MODULE__,
      Map.merge(attrs, %{
        module: module,
        name: attrs[:name] || inspect(module),
        model_opts: attrs[:model_opts] || [],
        validate_tools: attrs[:validate_tools] || false,
        tools: List.wrap(attrs[:tools] || []),
        middleware: List.wrap(attrs[:middleware] || []),
        interrupt_before: interrupt_value(attrs[:interrupt_before]),
        interrupt_after: interrupt_value(attrs[:interrupt_after])
      })
    )
  end

  defp interrupt_value(value) when value in [:all, "*"], do: :all
  defp interrupt_value(value), do: List.wrap(value || [])
end
