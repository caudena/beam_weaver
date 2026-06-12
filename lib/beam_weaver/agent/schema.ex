defmodule BeamWeaver.Agent.Schema do
  @moduledoc """
  Small explicit schema helpers for agent DSL declarations.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph

  @type field_spec :: %{name: term(), type: term(), required: boolean(), opts: keyword()}

  @spec field(term(), term(), keyword()) :: field_spec()
  def field(name, type, opts \\ []) do
    %{
      name: name,
      type: type,
      required: Keyword.get(opts, :required, false),
      opts: Keyword.drop(opts, [:required])
    }
  end

  @spec merge_schema(map() | nil, map() | nil) :: map()
  def merge_schema(left, right), do: Map.merge(left || %{}, right || %{})

  @spec validate_context(map() | nil, term()) :: :ok | {:error, Error.t()}
  def validate_context(nil, _context), do: :ok
  def validate_context(schema, nil), do: validate_context(schema, %{})

  def validate_context(schema, context) when is_map(schema) and is_map(context) do
    schema
    |> Enum.reduce_while(:ok, fn {key, spec}, :ok ->
      case validate_field(context, key, spec) do
        :ok -> {:cont, :ok}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  def validate_context(_schema, context) do
    {:error,
     Error.new(
       :invalid_context,
       "agent runtime context must be a map when context_schema is declared",
       %{
         context: inspect(context)
       }
     )}
  end

  @spec validate_input(map() | nil, term()) :: :ok | {:error, Error.t()}
  def validate_input(schema, input),
    do: validate_value_schema(schema, input, :invalid_agent_input, "agent input")

  @spec validate_output(map() | nil, term()) :: :ok | {:error, Error.t()}
  def validate_output(schema, output),
    do: validate_value_schema(schema, output, :invalid_agent_output, "agent output")

  @spec default_state_schema(boolean()) :: map()
  def default_state_schema(structured_response?) do
    schema = %{
      messages: BeamWeaver.Graph.Messages.channel(),
      remaining_steps: Graph.managed(BeamWeaver.Graph.Managed.RemainingSteps),
      jump_to: Graph.private_channel(BeamWeaver.Graph.Channels.EphemeralValue),
      tool_set: Graph.private_channel(BeamWeaver.Graph.Channels.LastValue),
      raw_input: Graph.private_channel(BeamWeaver.Graph.Channels.LastValue),
      usage:
        Graph.private_channel(
          {BeamWeaver.Graph.Channels.BinaryOperatorAggregate, &BeamWeaver.Agent.Usage.merge/2},
          initial: BeamWeaver.Agent.Usage.new()
        )
    }

    if structured_response? do
      Map.put(schema, :structured_response, Graph.channel(BeamWeaver.Graph.Channels.LastValue))
    else
      schema
    end
  end

  defp validate_value_schema(nil, _value, _error_type, _label), do: :ok

  defp validate_value_schema(schema, value, error_type, label)
       when is_map(schema) and is_map(value) do
    schema
    |> Enum.reduce_while(:ok, fn {key, spec}, :ok ->
      case validate_field(value, key, spec, error_type, label) do
        :ok -> {:cont, :ok}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp validate_value_schema(_schema, value, error_type, label) do
    {:error,
     Error.new(error_type, "#{label} must be a map when schema is declared", %{
       value: inspect(value)
     })}
  end

  defp validate_field(context, key, spec) do
    validate_field(context, key, spec, :invalid_context, "agent context")
  end

  defp validate_field(context, key, %{type: type, required: required}, error_type, label) do
    case fetch_value(context, key) do
      {:ok, value} ->
        if valid_type?(value, type) do
          :ok
        else
          {:error,
           Error.new(error_type, "#{label} field has invalid type", %{
             field: key,
             expected: type,
             actual: inspect(value)
           })}
        end

      :error ->
        if required do
          {:error, Error.new(error_type, "#{label} is missing required field", %{field: key})}
        else
          :ok
        end
    end
  end

  defp validate_field(_context, _key, _spec, _error_type, _label), do: :ok

  defp fetch_value(map, key) when is_atom(key) do
    cond do
      Map.has_key?(map, key) -> {:ok, Map.fetch!(map, key)}
      Map.has_key?(map, Atom.to_string(key)) -> {:ok, Map.fetch!(map, Atom.to_string(key))}
      true -> :error
    end
  end

  defp fetch_value(map, key) when is_binary(key) do
    cond do
      Map.has_key?(map, key) ->
        {:ok, Map.fetch!(map, key)}

      Enum.any?(Map.keys(map), &(to_string(&1) == key)) ->
        {:ok, map[Enum.find(Map.keys(map), &(to_string(&1) == key))]}

      true ->
        :error
    end
  end

  defp valid_type?(_value, :any), do: true
  defp valid_type?(value, :string), do: is_binary(value)
  defp valid_type?(value, :atom), do: is_atom(value)
  defp valid_type?(value, :integer), do: is_integer(value)
  defp valid_type?(value, :number), do: is_number(value)
  defp valid_type?(value, :boolean), do: is_boolean(value)
  defp valid_type?(value, :map), do: is_map(value)
  defp valid_type?(value, :list), do: is_list(value)
  defp valid_type?(nil, {:nullable, _type}), do: true
  defp valid_type?(value, {:nullable, type}), do: valid_type?(value, type)
  defp valid_type?(value, module) when is_atom(module), do: is_struct(value, module)
  defp valid_type?(_value, _type), do: true
end
