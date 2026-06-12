defmodule BeamWeaver.Graph.Schema do
  @moduledoc """
  Optional macro sugar for graph schemas.

  The runtime consumes plain data through `BeamWeaver.Schema`; this module only
  helps users declare JSON-schema-like maps at compile time.
  """

  defmacro __using__(_opts) do
    quote do
      import BeamWeaver.Graph.Schema, only: [field: 2, field: 3]
      Module.register_attribute(__MODULE__, :beam_weaver_schema_fields, accumulate: true)
      @before_compile BeamWeaver.Graph.Schema
    end
  end

  defmacro field(name, type, opts \\ []) do
    quote bind_quoted: [name: name, type: type, opts: opts] do
      @beam_weaver_schema_fields {name, type, opts}
    end
  end

  defmacro __before_compile__(env) do
    fields = Module.get_attribute(env.module, :beam_weaver_schema_fields) || []

    schema =
      fields
      |> Enum.reverse()
      |> Enum.reduce(%{"type" => "object", "properties" => %{}, "required" => []}, fn {name, type, opts}, acc ->
        key = to_string(name)

        property =
          type
          |> BeamWeaver.Schema.to_json_schema()
          |> BeamWeaver.Tool.Schema.stringify_schema()
          |> Map.merge(
            opts
            |> Keyword.get(:metadata, %{})
            |> Map.new()
            |> BeamWeaver.Tool.Schema.stringify_schema()
          )

        required =
          if Keyword.get(opts, :required, false),
            do: acc["required"] ++ [key],
            else: acc["required"]

        acc
        |> put_in(["properties", key], property)
        |> Map.put("required", required)
      end)

    quote do
      def __beam_weaver_schema__, do: unquote(Macro.escape(schema))
    end
  end
end
