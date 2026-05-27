defmodule BeamWeaver.Tool do
  @moduledoc """
  Macro-backed convenience for defining BeamWeaver tools.

  The macro compiles to a normal module implementing `BeamWeaver.Core.Tool`.
  """

  defmacro __using__(_opts) do
    quote do
      @behaviour BeamWeaver.Core.Tool
      import BeamWeaver.Tool
      Module.register_attribute(__MODULE__, :beam_weaver_tool_fields, accumulate: true)
      Module.register_attribute(__MODULE__, :beam_weaver_tool_injected, accumulate: true)
      @before_compile BeamWeaver.Tool
    end
  end

  defmacro name(value), do: quote(do: @beam_weaver_tool_name(unquote(value)))
  defmacro description(value), do: quote(do: @beam_weaver_tool_description(unquote(value)))

  defmacro response_format(value),
    do: quote(do: @beam_weaver_tool_response_format(unquote(value)))

  defmacro output_schema(value), do: quote(do: @beam_weaver_tool_output_schema(unquote(value)))
  defmacro tags(value), do: quote(do: @beam_weaver_tool_tags(unquote(value)))
  defmacro metadata(value), do: quote(do: @beam_weaver_tool_metadata(unquote(value)))
  defmacro provider_opts(value), do: quote(do: @beam_weaver_tool_provider_opts(unquote(value)))
  defmacro return_direct(value), do: quote(do: @beam_weaver_tool_return_direct(unquote(value)))
  defmacro concurrent(value), do: quote(do: @beam_weaver_tool_concurrent(unquote(value)))

  defmacro max_result_chars(value),
    do: quote(do: @beam_weaver_tool_max_result_chars(unquote(value)))

  defmacro injected(name, source) do
    quote bind_quoted: [name: name, source: source] do
      @beam_weaver_tool_injected {name, source}
    end
  end

  defmacro schema(do: block), do: block

  defmacro field(name, type, opts \\ []) do
    quote bind_quoted: [name: name, type: type, opts: opts] do
      @beam_weaver_tool_fields {name, type, opts}
    end
  end

  defmacro __before_compile__(env) do
    definition = BeamWeaver.Tool.Definition.from_module(env.module)

    quote do
      defstruct []

      def __beam_weaver_tool_definition__, do: unquote(Macro.escape(definition))

      @impl true
      def name(_tool), do: __beam_weaver_tool_definition__().name

      @impl true
      def description(_tool), do: __beam_weaver_tool_definition__().description

      @impl true
      def input_schema(_tool) do
        BeamWeaver.Tool.Schema.from_fields(__beam_weaver_tool_definition__().fields)
      end

      @impl true
      def injected(_tool), do: Map.new(__beam_weaver_tool_definition__().injected)

      @impl true
      def response_format(_tool), do: __beam_weaver_tool_definition__().response_format

      @impl true
      def output_schema(_tool), do: __beam_weaver_tool_definition__().output_schema

      @impl true
      def tags(_tool), do: __beam_weaver_tool_definition__().tags

      @impl true
      def metadata(_tool), do: __beam_weaver_tool_definition__().metadata

      @impl true
      def provider_opts(_tool), do: __beam_weaver_tool_definition__().provider_opts

      @impl true
      def return_direct(_tool), do: !!__beam_weaver_tool_definition__().return_direct

      @impl true
      def concurrent?(_tool), do: !!__beam_weaver_tool_definition__().concurrent

      @impl true
      def max_result_chars(_tool), do: __beam_weaver_tool_definition__().max_result_chars

      def __beam_weaver_tool__, do: true

      defoverridable name: 1,
                     description: 1,
                     input_schema: 1,
                     injected: 1,
                     response_format: 1,
                     output_schema: 1,
                     tags: 1,
                     metadata: 1,
                     provider_opts: 1,
                     return_direct: 1,
                     concurrent?: 1,
                     max_result_chars: 1
    end
  end
end
