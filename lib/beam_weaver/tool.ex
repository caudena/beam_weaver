defmodule BeamWeaver.Tool do
  @moduledoc ~S"""
  Defines a tool: an action the model can ask to run.

  ```elixir
  defmodule MyApp.Tools.LookupOrder do
    use BeamWeaver.Tool

    name "lookup_order"
    description "Look up the shipping status of an order by its id, such as A-1001."

    schema do
      field :order_id, :string, description: "The order id"
    end

    @impl true
    def invoke(_tool, %{"order_id" => order_id}, _opts), do: {:ok, "Order #{order_id} shipped on Monday."}
  end

  BeamWeaver.Core.Tool.invoke(MyApp.Tools.LookupOrder, %{"order_id" => "A-1001"})
  #=> {:ok, "Order A-1001 shipped on Monday."}
  ```

  `name` and `description` tell the model what the tool does (without
  `description`, the module's `@moduledoc` does), and `schema` declares its
  arguments with `field name, type, opts` (fields are required unless
  `required: false`). Arguments arrive under string keys, as the model
  sends them; values from `injected/2,3` arrive under their atom names.
  `invoke/3` returns `{:ok, result}` or `{:error, reason}`.

  List the module in an agent's `tools`. See [Tools](tools.md).
  """

  defmacro __using__(_opts) do
    quote do
      # Registered before `Core.Tool`'s hook, which then only fills the gaps.
      @before_compile BeamWeaver.Tool
      use BeamWeaver.Core.Tool
      import BeamWeaver.Tool
      Module.register_attribute(__MODULE__, :beam_weaver_tool_fields, accumulate: true)
      Module.register_attribute(__MODULE__, :beam_weaver_tool_injected, accumulate: true)
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

  defmacro injected(name, source, opts) do
    quote bind_quoted: [name: name, source: source, opts: opts] do
      @beam_weaver_tool_injected {name, source}

      if Keyword.has_key?(opts, :type) do
        field_opts =
          opts
          |> Keyword.take([:description, :enum, :default, :nullable, :properties, :items])
          |> Keyword.put(:required, false)

        @beam_weaver_tool_fields {name, Keyword.fetch!(opts, :type), field_opts}
      end
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
        __beam_weaver_tool_definition__().fields
        |> BeamWeaver.Tool.Schema.from_fields()
        |> BeamWeaver.Tool.Schema.Fields.string_property_names()
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
      def return_direct(_tool), do: __beam_weaver_tool_definition__().return_direct

      @impl true
      def concurrent?(_tool), do: __beam_weaver_tool_definition__().concurrent

      @impl true
      def max_result_chars(_tool), do: __beam_weaver_tool_definition__().max_result_chars

      def __beam_weaver_tool__, do: true
    end
  end
end
