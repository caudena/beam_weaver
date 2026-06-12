defmodule BeamWeaver.Agent.StructuredOutput.Policy do
  @moduledoc false

  alias BeamWeaver.Agent.StructuredOutput.AutoStrategy
  alias BeamWeaver.Agent.StructuredOutput.ProviderStrategy
  alias BeamWeaver.Agent.StructuredOutput.Schema
  alias BeamWeaver.Agent.StructuredOutput.ToolStrategy
  alias BeamWeaver.Models.Profile

  defstruct requested_strategy: nil,
            effective_strategy: nil,
            fallback_reason: nil,
            schema_bytes: 0,
            schema_properties: 0

  @type t :: %__MODULE__{
          requested_strategy: :auto | :provider | :tool | nil,
          effective_strategy: :provider | :tool | nil,
          fallback_reason: atom() | nil,
          schema_bytes: non_neg_integer(),
          schema_properties: non_neg_integer()
        }

  @spec choose(nil | AutoStrategy.t() | ProviderStrategy.t() | ToolStrategy.t(), term(), [term()]) ::
          {nil | ProviderStrategy.t() | ToolStrategy.t(), t()}
  def choose(nil, _model, _tools) do
    {nil, %__MODULE__{}}
  end

  def choose(%ToolStrategy{} = strategy, _model, _tools) do
    {strategy, policy(:tool, :tool, nil, strategy.schema_specs)}
  end

  def choose(%ProviderStrategy{} = strategy, model, tools) do
    case provider_decision(strategy.schema_spec, model, tools) do
      :ok ->
        {strategy, policy(:provider, :provider, nil, [strategy.schema_spec])}

      {:fallback, reason} ->
        {provider_to_tool_strategy(strategy), policy(:provider, :tool, reason, [strategy.schema_spec])}
    end
  end

  def choose(%AutoStrategy{schema: schema}, model, tools) do
    provider_strategy = BeamWeaver.Agent.StructuredOutput.provider(schema)

    case provider_decision(provider_strategy.schema_spec, model, tools) do
      :ok ->
        {provider_strategy, policy(:auto, :provider, nil, [provider_strategy.schema_spec])}

      {:fallback, reason} ->
        {BeamWeaver.Agent.StructuredOutput.tool(schema), policy(:auto, :tool, reason, [provider_strategy.schema_spec])}
    end
  end

  @spec to_metadata(t()) :: map()
  def to_metadata(%__MODULE__{} = policy) do
    %{
      structured_output_requested_strategy: policy.requested_strategy,
      structured_output_effective_strategy: policy.effective_strategy,
      structured_output_fallback_reason: policy.fallback_reason,
      structured_output_schema_bytes: policy.schema_bytes,
      structured_output_schema_properties: policy.schema_properties
    }
  end

  defp provider_to_tool_strategy(%ProviderStrategy{schema: schema, schema_spec: spec}) do
    %ToolStrategy{
      schema: schema,
      schema_specs: [spec || Schema.schema_spec(schema)]
    }
  end

  defp provider_decision(spec, model, tools) do
    cond do
      not provider_structured_output?(model) ->
        {:fallback, :provider_not_supported}

      tools_active?(tools) and not provider_structured_output_with_tools?(model) ->
        {:fallback, :tools_not_supported}

      over_limit?(schema_bytes(spec), schema_byte_limit(model)) ->
        {:fallback, :schema_too_large}

      over_limit?(schema_properties(spec), schema_property_limit(model)) ->
        {:fallback, :schema_too_many_properties}

      true ->
        :ok
    end
  end

  defp policy(requested, effective, reason, specs) do
    %__MODULE__{
      requested_strategy: requested,
      effective_strategy: effective,
      fallback_reason: reason,
      schema_bytes: schema_bytes(specs),
      schema_properties: schema_properties(specs)
    }
  end

  defp provider_structured_output?(model) do
    profile = profile(model)

    model_value(model, :supports_structured_output) == true or
      profile_value(profile, :structured_output) == true
  end

  defp provider_structured_output_with_tools?(model) do
    profile = profile(model)

    model_value(model, :supports_structured_output_with_tools) == true or
      profile_value(profile, :structured_output_with_tools) == true
  end

  defp schema_byte_limit(model) do
    model
    |> profile()
    |> profile_value(:structured_output_max_schema_bytes)
    |> finite_limit()
  end

  defp schema_property_limit(model) do
    model
    |> profile()
    |> profile_value(:structured_output_max_schema_properties)
    |> finite_limit()
  end

  defp finite_limit(value) when is_integer(value) and value >= 0, do: value
  defp finite_limit(_value), do: :infinity

  defp over_limit?(_value, :infinity), do: false
  defp over_limit?(value, limit), do: value > limit

  defp schema_bytes(nil), do: 0
  defp schema_bytes(specs) when is_list(specs), do: Enum.reduce(specs, 0, &(&2 + schema_bytes(&1)))
  defp schema_bytes(%{json_schema: schema}), do: schema_bytes(schema)

  defp schema_bytes(schema) when is_map(schema) do
    case BeamWeaver.JSON.encode(schema) do
      {:ok, json} -> byte_size(json)
      {:error, _error} -> 0
    end
  end

  defp schema_bytes(_schema), do: 0

  defp schema_properties(nil), do: 0
  defp schema_properties(specs) when is_list(specs), do: Enum.reduce(specs, 0, &(&2 + schema_properties(&1)))
  defp schema_properties(%{json_schema: schema}), do: schema_properties(schema)
  defp schema_properties(schema) when is_map(schema), do: count_properties(schema, 0)
  defp schema_properties(_schema), do: 0

  defp count_properties(_schema, count) when count > 10_000, do: count

  defp count_properties(%{} = schema, count) do
    property_count =
      case BeamWeaver.MapAccess.get(schema, :properties) do
        properties when is_map(properties) -> map_size(properties)
        _other -> 0
      end

    schema
    |> Map.values()
    |> Enum.reduce(count + property_count, &count_properties/2)
  end

  defp count_properties(values, count) when is_list(values) do
    Enum.reduce(values, count, &count_properties/2)
  end

  defp count_properties(_schema, count), do: count

  defp tools_active?(tools), do: List.wrap(tools) != []

  defp profile(%Profile{} = profile), do: profile
  defp profile(model) when is_map(model), do: BeamWeaver.MapAccess.get(model, :profile)
  defp profile(_model), do: nil

  defp model_value(model, key) when is_map(model), do: BeamWeaver.MapAccess.get(model, key)
  defp model_value(_model, _key), do: nil

  defp profile_value(%Profile{} = profile, key), do: Map.get(profile, key)
  defp profile_value(profile, key) when is_map(profile), do: BeamWeaver.MapAccess.get(profile, key)
  defp profile_value(_profile, _key), do: nil
end
