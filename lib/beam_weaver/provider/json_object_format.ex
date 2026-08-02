defmodule BeamWeaver.Provider.JsonObjectFormat do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.JSON
  alias BeamWeaver.MapAccess

  @wire_format %{"type" => "json_object"}

  @spec normalize(term(), keyword()) ::
          {:ok, map() | nil, map() | nil} | {:error, struct()}
  def normalize(format, opts \\ [])

  def normalize(nil, _opts), do: {:ok, nil, nil}

  def normalize(%{"type" => type}, _opts) when type in [:json_object, "json_object"],
    do: {:ok, @wire_format, nil}

  def normalize(%{type: type}, _opts) when type in [:json_object, "json_object"],
    do: {:ok, @wire_format, nil}

  def normalize(%{name: name, schema: schema} = format, _opts)
      when is_binary(name) and is_map(schema) do
    {:ok, @wire_format, instruction(name, schema, Map.get(format, :strict))}
  end

  def normalize(%{"name" => name, "schema" => schema} = format, _opts)
      when is_binary(name) and is_map(schema) do
    {:ok, @wire_format, instruction(name, schema, Map.get(format, "strict"))}
  end

  def normalize({name, schema}, _opts) when is_binary(name) and is_map(schema) do
    {:ok, @wire_format, instruction(name, schema)}
  end

  def normalize(other, opts) do
    error_module = Keyword.get(opts, :error_module, Error)
    message = Keyword.get(opts, :error_message, "provider supports JSON object response_format only")

    details =
      Keyword.get(opts, :error_details, %{})
      |> Map.merge(%{
        response_format: inspect(other),
        supported: [@wire_format]
      })

    {:error, apply(error_module, :new, [:invalid_response_format, message, details])}
  end

  @spec instruction(String.t(), map(), boolean() | nil) :: map()
  def instruction(name, schema, strict \\ nil) when is_binary(name) and is_map(schema) do
    %{
      "role" => "system",
      "content" => instruction_text(name, schema, strict)
    }
  end

  @spec inject_instruction([map()], map() | nil) :: [map()]
  def inject_instruction(messages, nil) when is_list(messages), do: messages

  def inject_instruction(messages, instruction)
      when is_list(messages) and is_map(instruction) do
    {system_messages, rest} =
      Enum.split_while(messages, fn message ->
        Map.get(message, "role") == "system"
      end)

    system_messages ++ [instruction] ++ rest
  end

  defp instruction_text(name, schema, strict) do
    schema = BeamWeaver.MapShape.normalize_value(schema)
    required = schema |> MapAccess.get(:required, []) |> List.wrap()
    required_text = if required == [], do: "none", else: Enum.map_join(required, ", ", &to_string/1)

    strict_text =
      if strict == false, do: "Validate against this schema.", else: "Strictly validate against this schema."

    """
    BeamWeaver structured output contract:
    - Return exactly one JSON object and no markdown, prose, code fences, or commentary.
    - #{strict_text}
    - Include every required key. Required keys: #{required_text}.
    - If information is unavailable, still include the key with a value compatible with the schema.

    Schema name: #{name}
    JSON Schema:
    #{JSON.encode!(schema, pretty: true)}
    """
    |> String.trim()
  end
end
