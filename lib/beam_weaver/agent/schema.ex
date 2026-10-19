defmodule BeamWeaver.Agent.Schema do
  @moduledoc ~S"""
  Runtime field contracts for agent context, input and output state.

  Fields are optional unless `required: true`, unlike tool/response schema fields.
  Context validation runs before model execution. Input/output schemas describe
  application state, not the model's structured answer; use `BeamWeaver.Schema`
  and `response_schema` for that separate contract.

  `merge_schema/2` layers right-hand fields over left-hand fields. Validation
  returns :ok or a typed error identifying invalid data. See
  [Runtime Context](runtime_context.md) and [Agents](agents.md#declarations).
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph

  @type field_spec :: %{name: term(), type: term(), required: boolean(), opts: keyword()}

  # Built-in types whose values are structs.
  @struct_types %{date: Date, time: Time, utc_datetime: DateTime, naive_datetime: NaiveDateTime}

  @doc """
  A field of a context, input or output schema. `required: true` makes it
  required; fields are optional by default.

  The type is one of `:string`, `:integer`, `:number`, `:float`, `:decimal`,
  `:boolean`, `:atom`, `:map`, `:list`, `:date`, `:time`, `:utc_datetime`,
  `:naive_datetime`, `:any`, `{:list, type}`, `{:nullable, type}`,
  `{:union, [type, ...]}`, or a struct module, whose struct the value must be.
  `:float` and `:decimal` accept any number, and `:decimal` also a `Decimal`.
  """
  @spec field(term(), term(), keyword()) :: field_spec()
  def field(name, type, opts \\ []) do
    %{
      name: name,
      type: type,
      required: Keyword.get(opts, :required, false),
      opts: Keyword.drop(opts, [:required])
    }
  end

  @doc """
  Merges field maps with right-hand entries winning; nil behaves as an empty map.
  """
  @spec merge_schema(map() | nil, map() | nil) :: map()
  def merge_schema(left, right), do: Map.merge(left || %{}, right || %{})

  @doc """
  Checks context fields and returns :invalid_context for invalid caller data.
  """
  @spec validate_context(map() | nil, term()) :: :ok | {:error, Error.t()}
  def validate_context(nil, _context), do: :ok
  def validate_context(schema, nil), do: validate_context(schema, %{})

  def validate_context(schema, context) when is_map(schema) and is_map(context),
    do: validate_value_schema(schema, context, :invalid_context, "agent context")

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

  @doc false
  # Validates a call's context and returns it with every declared field that
  # came under a string key moved to its atom key, so tools and middleware
  # read it the same way however the caller wrote it.
  @spec normalize_context(map() | nil, term()) :: {:ok, term()} | {:error, Error.t()}
  def normalize_context(schema, context) do
    with :ok <- validate_context(schema, context), do: {:ok, atomize_declared_keys(schema, context)}
  end

  defp atomize_declared_keys(schema, context) when is_map(schema) and is_map(context) do
    Enum.reduce(schema, context, fn
      {key, _spec}, acc when is_atom(key) ->
        string_key = Atom.to_string(key)

        case acc do
          %{^key => _value} -> Map.delete(acc, string_key)
          %{^string_key => value} -> acc |> Map.delete(string_key) |> Map.put(key, value)
          _other -> acc
        end

      _field, acc ->
        acc
    end)
  end

  defp atomize_declared_keys(_schema, context), do: context

  @doc """
  Checks state input against an explicit field schema.
  """
  @spec validate_input(map() | nil, term()) :: :ok | {:error, Error.t()}
  def validate_input(schema, input),
    do: validate_value_schema(schema, input, :invalid_agent_input, "agent input")

  @doc """
  Checks the final state against an explicit output field schema.
  """
  @spec validate_output(map() | nil, term()) :: :ok | {:error, Error.t()}
  def validate_output(schema, output),
    do: validate_value_schema(schema, output, :invalid_agent_output, "agent output")

  # `tool_set` holds the tools the model was offered on its latest call, for
  # the tools node; tools can't be saved, so `tool_set_names` keeps their
  # names in the thread's checkpoints, for a run that continues from one.
  @doc """
  Builds the agent runtime's message, private-bookkeeping and managed-step channels.
  """
  @spec default_state_schema(boolean()) :: map()
  def default_state_schema(structured_response?) do
    schema = %{
      messages: BeamWeaver.Graph.Messages.channel(),
      remaining_steps: Graph.managed(BeamWeaver.Graph.Managed.RemainingSteps),
      jump_to: Graph.private_channel(BeamWeaver.Graph.Channels.EphemeralValue),
      tool_set: Graph.private_channel(BeamWeaver.Graph.Channels.LastValue),
      tool_set_names: Graph.private_channel(BeamWeaver.Graph.Channels.LastValue, checkpoint: true),
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

  defp validate_value_schema(schema, value, error_type, label) when is_map(schema) and is_map(value) do
    Enum.find_value(schema, :ok, fn {key, spec} ->
      with :ok <- validate_field(value, key, spec, error_type, label), do: nil
    end)
  end

  defp validate_value_schema(_schema, value, error_type, label) do
    {:error,
     Error.new(error_type, "#{label} must be a map when schema is declared", %{
       value: inspect(value)
     })}
  end

  defp validate_field(context, key, %{type: type, required: required}, error_type, label) do
    case BeamWeaver.MapAccess.fetch(context, key) do
      {:ok, value} ->
        case check_type(value, type) do
          true ->
            :ok

          false ->
            {:error,
             Error.new(error_type, "#{label} field has invalid type", %{
               field: key,
               expected: type,
               actual: inspect(value)
             })}

          :unknown_type ->
            {:error,
             Error.new(:invalid_agent, "#{label} field has an unknown type", %{
               field: key,
               type: inspect(type)
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

  # true or false for a known type, :unknown_type for a type no value can be
  # checked against, such as a misspelled atom.
  defp check_type(_value, :any), do: true
  defp check_type(value, type) when type in [:string, :binary, :binary_id], do: is_binary(value)
  defp check_type(value, :atom), do: is_atom(value)
  defp check_type(value, type) when type in [:integer, :id], do: is_integer(value)
  defp check_type(value, type) when type in [:number, :float], do: is_number(value)
  defp check_type(value, :decimal), do: is_number(value) or is_struct(value, Decimal)
  defp check_type(value, :boolean), do: is_boolean(value)
  defp check_type(value, type) when type in [:map, :object], do: is_map(value)
  defp check_type(value, type) when type in [:list, :array], do: is_list(value)
  defp check_type(value, :null), do: is_nil(value)
  defp check_type(value, type) when is_map_key(@struct_types, type), do: is_struct(value, @struct_types[type])
  defp check_type(nil, {:nullable, _type}), do: true
  defp check_type(value, {:nullable, type}), do: check_type(value, type)
  defp check_type(value, {:object, _fields}), do: is_map(value)

  defp check_type(value, {kind, type}) when kind in [:list, :array] do
    if is_list(value), do: check_all(value, type), else: false
  end

  defp check_type(value, {:union, types}) when is_list(types) do
    results = Enum.map(types, &check_type(value, &1))

    cond do
      true in results -> true
      :unknown_type in results -> :unknown_type
      true -> false
    end
  end

  defp check_type(value, module) when is_atom(module) do
    cond do
      BeamWeaver.Behaviour.exported?(module, :__struct__, 0) -> is_struct(value, module)
      BeamWeaver.Behaviour.exported?(module, :json_schema, 0) -> is_map(value)
      true -> :unknown_type
    end
  end

  defp check_type(_value, _type), do: :unknown_type

  defp check_all(values, type) do
    Enum.reduce_while(values, true, fn value, true ->
      case check_type(value, type) do
        true -> {:cont, true}
        other -> {:halt, other}
      end
    end)
  end
end
