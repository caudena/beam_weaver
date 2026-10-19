defmodule BeamWeaver.Agent.StructuredOutput do
  @moduledoc ~S"""
  Construct and resolve final-answer strategies for agents.

  `auto/2` prefers a compatible native provider response and otherwise uses a
  schema tool. `provider/2` expresses a native preference, with compatibility
  fallback during strategy selection. `tool/2` requests the answer as tool
  arguments and can feed validation failures back to the model.

  Schemas can be BeamWeaver schema modules or supported JSON Schema forms.
  Normalized answers use string keys. Local validation checks required top-level
  keys and basic types, not every nested constraint or business rule.
  Use the [Schema DSL guide](structured_output.md) for executable real-provider
  examples, option precedence and retry behavior.
  """

  alias BeamWeaver.Agent.StructuredOutput.AutoStrategy
  alias BeamWeaver.Agent.StructuredOutput.Policy
  alias BeamWeaver.Agent.StructuredOutput.ProviderStrategy
  alias BeamWeaver.Agent.StructuredOutput.ResultHandler
  alias BeamWeaver.Agent.StructuredOutput.Schema
  alias BeamWeaver.Agent.StructuredOutput.SchemaSpec
  alias BeamWeaver.Agent.StructuredOutput.ToolStrategy
  alias BeamWeaver.Agent.StructuredOutput.Validation
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool

  @auto_opts [:name, :description, :strict, :tool_message_content, :handle_errors, :max_retries]

  @doc """
  Builds an automatic strategy; compatibility selection occurs against the actual model and tools.
  """
  @spec auto(term(), keyword()) :: AutoStrategy.t()
  def auto(schema, opts \\ []),
    do: %AutoStrategy{schema: schema, opts: opts |> List.wrap() |> Keyword.take(@auto_opts)}

  @doc """
  The tool strategy: the model answers by calling a tool named after the
  schema.

  Options: `:tool_message_content`, the text of the tool message that records
  the answer; `:handle_errors` (default `true`), which sends an answer that
  fails the schema back to the model as an error tool message, or `false` to
  return the error; and `:max_retries` (default 2), how many times the model
  may answer again before the error is returned.
  """
  @spec tool(term(), keyword()) :: ToolStrategy.t()
  def tool(schema, opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, 2)

    unless is_integer(max_retries) and max_retries >= 0 do
      raise ArgumentError, "max_retries must be a non-negative integer, got: #{inspect(max_retries)}"
    end

    %ToolStrategy{
      schema: schema,
      tool_message_content: Keyword.get(opts, :tool_message_content),
      handle_errors: Keyword.get(opts, :handle_errors, true),
      max_retries: max_retries,
      schema_specs: Schema.schema_specs(schema)
    }
  end

  @doc """
  Builds a provider-native preference with optional name, description and strict settings.
  """
  @spec provider(term(), keyword()) :: ProviderStrategy.t()
  def provider(schema, opts \\ []) do
    spec = Schema.schema_spec(schema, Keyword.take(opts, [:name, :description, :strict]))
    %ProviderStrategy{schema: schema, schema_spec: spec, strict: Keyword.get(opts, :strict)}
  end

  @doc """
  Normalizes a schema or strategy; nil disables structured output.
  """
  @spec normalize(term()) :: nil | AutoStrategy.t() | ToolStrategy.t() | ProviderStrategy.t()
  def normalize(nil), do: nil
  def normalize(%AutoStrategy{} = strategy), do: strategy

  def normalize(%ToolStrategy{} = strategy),
    do: %{strategy | schema_specs: Schema.schema_specs(strategy.schema)}

  def normalize(%ProviderStrategy{} = strategy), do: strategy
  def normalize(schema), do: auto(schema)

  @doc """
  Selects the effective strategy for the model profile and whether ordinary tools are present.
  """
  @spec effective_strategy(term(), term(), [term()]) :: term()
  def effective_strategy(response_format, model, tools) do
    response_format
    |> effective_strategy_info(model, tools)
    |> elem(0)
  end

  @doc """
  Returns the selected strategy together with its compatibility-policy details.
  """
  @spec effective_strategy_info(term(), term(), [term()]) :: {term(), struct()}
  def effective_strategy_info(response_format, model, tools),
    do: Policy.choose(response_format, model, tools)

  @doc """
  Builds schema-answer tools for tool strategies; provider strategies add no such tools.
  """
  @spec setup_tools(term()) :: [Tool.t()]
  def setup_tools(%AutoStrategy{schema: schema}), do: setup_tools(tool(schema))

  def setup_tools(%ToolStrategy{schema_specs: specs}) do
    Enum.map(specs, fn spec ->
      Tool.from_function!(
        name: spec.name,
        description: Schema.nonempty_description(spec.description),
        input_schema: spec.json_schema,
        metadata: %{structured_response: true, structured_output_schema: spec.name},
        handler: fn args, _opts -> args end
      )
    end)
  end

  def setup_tools(_strategy), do: []

  # Strict schema adherence is the provider default; a strategy that does not
  # say otherwise asks for it explicitly, so an unset value never reaches the
  # wire as null (which providers read as "not strict").
  @spec provider_opts(ProviderStrategy.t()) :: keyword()
  def provider_opts(%ProviderStrategy{schema_spec: spec, strict: strict}) do
    [
      response_format: %{
        name: spec.name,
        schema: spec.json_schema,
        strict: strict != false,
        validator: fn data -> Validation.validate_data(spec, data) end
      }
    ]
  end

  @doc """
  Handles a model message according to a structured-output strategy.

  `history` is the conversation the model answered; the tool strategy counts
  the answers that already failed in it against `max_retries`.
  """
  @spec handle_model_output(Message.t(), term(), [Message.t()]) ::
          {:ok, BeamWeaver.Agent.ModelResponse.t()} | {:error, Error.t()}
  defdelegate handle_model_output(message, strategy, history \\ []), to: ResultHandler

  @doc "Returns schema specs for a supported structured-output schema."
  @spec schema_specs(term()) :: [SchemaSpec.t()]
  defdelegate schema_specs(schema), to: Schema

  @doc "Returns one schema spec for a supported structured-output schema."
  @spec schema_spec(term(), keyword()) :: SchemaSpec.t()
  defdelegate schema_spec(schema, opts \\ []), to: Schema

  @doc "Parses structured data against a schema spec."
  @spec parse(SchemaSpec.t(), map()) :: {:ok, term()} | {:error, Error.t()}
  defdelegate parse(spec, data), to: Validation

  @doc "Validates structured data against a schema spec."
  @spec validate_data(SchemaSpec.t(), map()) :: :ok | {:error, Error.t()}
  defdelegate validate_data(spec, data), to: Validation
end
