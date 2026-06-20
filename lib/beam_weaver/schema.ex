defmodule BeamWeaver.Schema do
  @moduledoc """
  JSON-schema declarations for BeamWeaver tools, structured outputs, and graph views.

  Use this module when a schema is part of your public agent contract:

      defmodule MyApp.Schemas.FactsOutput do
        use BeamWeaver.Schema

        title "facts_output"
        description "Extracted entity facts and client requests."
        strict true

        field :entity_facts, {:array, MyApp.Schemas.EntityFact}, required: true
      end

  Runtime code consumes schemas through `to_json_schema/1`. Maps are returned as
  JSON schema maps; schema modules can expose `json_schema/0`, `schema/0`, or the
  legacy `__beam_weaver_schema__/0` callback.
  """

  defmacro __using__(_opts) do
    quote do
      import BeamWeaver.Schema,
        only: [
          title: 1,
          description: 1,
          strict: 1,
          field: 2,
          field: 3
        ]

      Module.register_attribute(__MODULE__, :beam_weaver_schema_fields, accumulate: true)
      @before_compile BeamWeaver.Schema
    end
  end

  defmacro title(value), do: quote(do: @beam_weaver_schema_title(unquote(value)))
  defmacro description(value), do: quote(do: @beam_weaver_schema_description(unquote(value)))
  defmacro strict(value), do: quote(do: @beam_weaver_schema_strict(unquote(value)))

  defmacro field(name_ast, type, opts \\ []) do
    name = literal_field_name!(__CALLER__, name_ast)

    quote bind_quoted: [name: name, type: Macro.escape(type), opts: opts] do
      @beam_weaver_schema_fields {name, type, opts}
    end
  end

  defmacro __before_compile__(env) do
    title = Module.get_attribute(env.module, :beam_weaver_schema_title) || schema_default_title(env.module)
    description = Module.get_attribute(env.module, :beam_weaver_schema_description) || ""
    strict? = Module.get_attribute(env.module, :beam_weaver_schema_strict) == true
    fields = Module.get_attribute(env.module, :beam_weaver_schema_fields) || []
    schema = object_schema(Enum.reverse(fields), title, description, strict?)

    quote do
      def json_schema, do: unquote(Macro.escape(schema))
      def schema, do: json_schema()
      def __beam_weaver_schema__, do: json_schema()
    end
  end

  @spec to_json_schema(term()) :: map()
  def to_json_schema(schema) when is_map(schema), do: schema

  def to_json_schema(module) when is_atom(module) do
    ensure_schema_module_compiled(module)

    cond do
      function_exported?(module, :json_schema, 0) ->
        module.json_schema()

      function_exported?(module, :schema, 0) ->
        module.schema()

      function_exported?(module, :__beam_weaver_schema__, 0) ->
        module.__beam_weaver_schema__()

      true ->
        BeamWeaver.Tool.Schema.type_schema(module)
    end
  end

  def to_json_schema({:array, item_type}) do
    %{"type" => "array", "items" => to_json_schema(item_type)}
  end

  def to_json_schema({:object, fields}) when is_list(fields) do
    object_schema(fields, nil, nil, false)
  end

  def to_json_schema({:union, types}) when is_list(types) do
    %{"anyOf" => Enum.map(types, &to_json_schema/1)}
  end

  def to_json_schema(type), do: BeamWeaver.Tool.Schema.type_schema(type) |> stringify_schema()

  defp object_schema(fields, title, description, strict?) do
    {properties, required} =
      Enum.reduce(fields, {%{}, []}, fn {name, type, opts}, {properties, required} ->
        key = to_string(name)

        property =
          type
          |> field_type_schema()
          |> merge_field_opts(opts)
          |> stringify_schema()

        required =
          if Keyword.get(opts, :required, true),
            do: required ++ [key],
            else: required

        {Map.put(properties, key, property), required}
      end)

    %{
      "type" => "object",
      "properties" => properties,
      "required" => required
    }
    |> maybe_put("title", title)
    |> maybe_put("description", description)
    |> maybe_put("additionalProperties", false, strict?)
  end

  defp field_type_schema({:array, item_type}) do
    %{"type" => "array", "items" => to_json_schema(item_type)}
  end

  defp field_type_schema({:object, fields}) when is_list(fields), do: object_schema(fields, nil, nil, false)
  defp field_type_schema({:union, types}) when is_list(types), do: %{"anyOf" => Enum.map(types, &to_json_schema/1)}
  defp field_type_schema(type), do: to_json_schema(type)

  defp merge_field_opts(schema, opts) do
    schema
    |> maybe_put("description", Keyword.get(opts, :description))
    |> maybe_put("enum", Keyword.get(opts, :enum))
    |> maybe_put_default(opts)
    |> maybe_nullable(Keyword.get(opts, :nullable, false))
    |> maybe_put("additionalProperties", false, Keyword.get(opts, :strict, false))
  end

  defp maybe_put_default(schema, opts) do
    if Keyword.has_key?(opts, :default),
      do: Map.put(schema, "default", Keyword.get(opts, :default)),
      else: schema
  end

  defp maybe_nullable(schema, false), do: schema

  defp maybe_nullable(schema, true) do
    type = Map.get(schema, "type")
    Map.put(schema, "type", Enum.uniq(List.wrap(type) ++ ["null"]))
  end

  defp maybe_put(schema, _key, nil), do: schema
  defp maybe_put(schema, key, value), do: Map.put(schema, key, value)

  defp maybe_put(schema, key, value, true), do: maybe_put(schema, key, value)
  defp maybe_put(schema, _key, _value, false), do: schema

  defp stringify_schema(schema), do: BeamWeaver.MapShape.stringify_keys(schema)

  defp schema_default_title(module), do: module |> Module.split() |> List.last() |> Macro.underscore()

  defp literal_field_name!(_caller, name) when is_atom(name), do: name

  defp literal_field_name!(caller, other) do
    expanded = Macro.expand(other, caller)

    if is_atom(expanded) do
      expanded
    else
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description: "schema field names must be literal atoms"
    end
  end

  defp ensure_schema_module_compiled(module) do
    case Code.ensure_compiled(module) do
      {:module, _module} ->
        :ok

      {:error, :nofile} ->
        :error

      {:error, reason} ->
        raise ArgumentError, "schema module #{inspect(module)} could not be loaded: #{inspect(reason)}"
    end
  end
end
