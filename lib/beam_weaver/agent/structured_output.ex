defmodule BeamWeaver.Agent.StructuredOutput do
  @moduledoc """
  Structured response strategies for agent model calls.
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

  @spec auto(term()) :: AutoStrategy.t()
  def auto(schema), do: %AutoStrategy{schema: schema}

  @spec tool(term(), keyword()) :: ToolStrategy.t()
  def tool(schema, opts \\ []) do
    %ToolStrategy{
      schema: schema,
      tool_message_content: Keyword.get(opts, :tool_message_content),
      handle_errors: Keyword.get(opts, :handle_errors, true),
      schema_specs: Schema.schema_specs(schema)
    }
  end

  @spec provider(term(), keyword()) :: ProviderStrategy.t()
  def provider(schema, opts \\ []) do
    spec = Schema.schema_spec(schema, Keyword.take(opts, [:name, :description, :strict]))
    %ProviderStrategy{schema: schema, schema_spec: spec, strict: Keyword.get(opts, :strict)}
  end

  @spec normalize(term()) :: nil | AutoStrategy.t() | ToolStrategy.t() | ProviderStrategy.t()
  def normalize(nil), do: nil
  def normalize(%AutoStrategy{} = strategy), do: strategy

  def normalize(%ToolStrategy{} = strategy),
    do: %{strategy | schema_specs: Schema.schema_specs(strategy.schema)}

  def normalize(%ProviderStrategy{} = strategy), do: strategy
  def normalize(schema), do: auto(schema)

  @spec effective_strategy(term(), term(), [term()]) :: term()
  def effective_strategy(response_format, model, tools) do
    response_format
    |> effective_strategy_info(model, tools)
    |> elem(0)
  end

  @spec effective_strategy_info(term(), term(), [term()]) :: {term(), Policy.t()}
  def effective_strategy_info(response_format, model, tools),
    do: Policy.choose(response_format, model, tools)

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

  @spec provider_opts(ProviderStrategy.t()) :: keyword()
  def provider_opts(%ProviderStrategy{schema_spec: spec, strict: strict}) do
    [
      response_format: %{
        name: spec.name,
        schema: spec.json_schema,
        strict: strict,
        validator: fn data -> Validation.validate_data(spec, data) end
      }
    ]
  end

  @doc "Handles a model message according to a structured-output strategy."
  @spec handle_model_output(Message.t(), term()) ::
          {:ok, BeamWeaver.Agent.ModelResponse.t()} | {:error, Error.t()}
  defdelegate handle_model_output(message, strategy), to: ResultHandler

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
