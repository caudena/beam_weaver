defmodule BeamWeaver.Tool.DSLTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Runnable
  alias BeamWeaver.Tool.Converter
  alias BeamWeaver.Tool.Renderer

  defmodule SearchDocs do
    use BeamWeaver.Tool

    name("search_docs")
    description("Search support documentation")
    tags([:support])
    metadata(%{owner: "docs"})
    provider_opts(%{openai: %{strict: true}})
    response_format(:content_and_artifact)
    output_schema(%{type: "object", properties: %{results: %{type: "array"}}})
    concurrent(false)
    max_result_chars(120)
    injected(:runtime, :runtime)

    schema do
      field(:query, :string, description: "Search query")
      field(:limit, :integer, required: false, default: 5)
      field(:runtime, :object)

      field(:filters, :object,
        required: false,
        properties: %{section: %{type: "string", enum: ["billing", "support"]}}
      )
    end

    @impl true
    def invoke(_tool, input, _opts) do
      {:ok, %{query: input.query, limit: Map.get(input, :limit, 5)}}
    end
  end

  defmodule ListOrders do
    use BeamWeaver.Tool

    name("list_orders")
    description("List orders by status")
    injected(:tool_call_id, :tool_call_id, type: :string)

    schema do
      field(:status, :string)
      field(:limit, :integer, required: false, default: 10)
      field(:include_archived, :boolean, required: false, default: true)

      field(:range, {:object, [{:from, :date}, {:to, :date, required: false}]}, required: false)
    end

    @impl true
    def invoke(_tool, input, _opts), do: {:ok, input}
  end

  defmodule DirectTool do
    @behaviour BeamWeaver.Core.Tool

    defstruct []

    def name(_tool), do: "direct_tool"
    def description(_tool), do: "Direct behaviour tool"

    def input_schema(_tool),
      do: %{type: "object", properties: %{value: %{type: "string"}}, required: [:value]}

    def injected(_tool), do: %{}
    def return_direct(_tool), do: false
    def invoke(_tool, input, _opts), do: {:ok, String.upcase(input.value)}
  end

  defmodule DemoToolkit do
    @behaviour BeamWeaver.ToolKit

    def tools(_opts), do: [SearchDocs, %DirectTool{}]
  end

  test "module DSL compiles to a normal executable tool behaviour" do
    assert Tool.name(SearchDocs) == "search_docs"
    assert Tool.description(%SearchDocs{}) == "Search support documentation"
    assert Tool.tags(%SearchDocs{}) == [:support]
    assert Tool.metadata(%SearchDocs{}) == %{owner: "docs"}
    assert Tool.response_format(%SearchDocs{}) == :content_and_artifact
    refute Tool.concurrent?(%SearchDocs{})
    assert Tool.max_result_chars(%SearchDocs{}) == 120

    assert Tool.output_schema(%SearchDocs{}) == %{
             type: "object",
             properties: %{results: %{type: "array"}}
           }

    assert Tool.raw_input_schema(%SearchDocs{}).properties["runtime"].type == "object"
    refute Map.has_key?(Tool.input_schema(%SearchDocs{}).properties, "runtime")

    assert {:ok, %{query: "refunds", limit: 5}} =
             Tool.invoke(%SearchDocs{}, %{query: "refunds", runtime: %{}})
  end

  test "the generated schema uses string property names, like a hand-written JSON schema" do
    assert Tool.input_schema(ListOrders) == %{
             type: "object",
             properties: %{
               "status" => %{type: "string"},
               "limit" => %{type: "integer", default: 10},
               "include_archived" => %{type: "boolean", default: true},
               "range" => %{
                 type: "object",
                 properties: %{
                   "from" => %{type: "string", format: "date"},
                   "to" => %{type: "string", format: "date"}
                 },
                 required: ["from"]
               }
             },
             required: ["status"]
           }

    assert Map.keys(Tool.raw_input_schema(ListOrders).properties) |> Enum.sort() ==
             ["include_archived", "limit", "range", "status", "tool_call_id"]
  end

  test "a model call delivers declared fields under string keys, defaults included" do
    # Arguments decoded from a model's JSON have string keys.
    assert {:ok, input} = Tool.invoke(ListOrders, %{"status" => "shipped"})
    assert input == %{"status" => "shipped", "limit" => 10, "include_archived" => true}

    # A value the model sends wins over the default, false included.
    assert {:ok, input} =
             Tool.invoke(ListOrders, %{"status" => "shipped", "limit" => 3, "include_archived" => false})

    assert input == %{"status" => "shipped", "limit" => 3, "include_archived" => false}

    # Injected arguments keep their atom names.
    assert {:ok, input} = Tool.invoke(ListOrders, %{"status" => "new", tool_call_id: "call_1"})
    assert input == %{"status" => "new", "limit" => 10, "include_archived" => true, tool_call_id: "call_1"}
  end

  test "a direct call keeps the caller's keys for the arguments it supplies" do
    assert {:ok, %{"limit" => 10, "include_archived" => true, status: "shipped"}} =
             Tool.invoke(ListOrders, %{status: "shipped"})
  end

  test "schema blocks validate nested objects, enums, and types before handler execution" do
    assert :ok =
             Tool.validate_input(Tool.input_schema(%SearchDocs{}), %{
               query: "refund",
               filters: %{section: "billing"}
             })

    assert {:error, error} =
             Tool.validate_input(Tool.input_schema(%SearchDocs{}), %{
               query: "refund",
               filters: %{section: "unknown"}
             })

    assert error.type == :invalid_input
    assert error.message == "tool input is not in enum"
  end

  test "direct behaviour modules work without the macro" do
    assert {:ok, "ADA"} = Tool.invoke(%DirectTool{}, %{value: "ada"})
    assert Tool.input_schema(%DirectTool{}).required == [:value]
  end

  test "converter handles modules, structs, toolkits, and duplicate toolkit names" do
    assert {:ok, tool} = Converter.to_tool(SearchDocs)
    assert %Tool{} = tool
    assert Tool.name(tool) == "search_docs"

    assert {:ok, [search, direct]} = Converter.to_tools(DemoToolkit)
    assert Enum.map([search, direct], &Tool.name/1) == ["search_docs", "direct_tool"]

    assert {:error, error} = Converter.to_tools([SearchDocs, %SearchDocs{}])
    assert error.type == :duplicate_tool
  end

  test "runnable conversion invokes the runnable through the tool boundary" do
    runnable =
      Runnable.lambda(fn input, _opts -> {:ok, %{echo: input["value"] || input[:value]}} end)

    assert {:ok, tool} =
             Converter.to_tool(runnable,
               name: "echo",
               description: "Echoes input",
               input_schema: %{
                 type: "object",
                 properties: %{value: %{type: "string"}},
                 required: [:value]
               }
             )

    assert {:ok, %{echo: "hello"}} = Tool.invoke(tool, %{value: "hello"})
  end

  test "provider-safe name validation happens while rendering provider schemas" do
    internal =
      Tool.from_function!(
        name: "bad tool name",
        description: "Invalid for providers",
        input_schema: %{},
        handler: fn _input, _opts -> :ok end
      )

    assert {:error, error} = Renderer.openai_tool(internal)
    assert error.type == :invalid_tool_name

    assert {:ok, rendered} = Renderer.openai_tool(%SearchDocs{})
    assert rendered["type"] == "function"
    assert rendered["name"] == "search_docs"
    refute Map.has_key?(rendered["parameters"]["properties"], "runtime")
  end

  test "renders text tool descriptions with public argument schemas" do
    description = Renderer.render_text_description([%SearchDocs{}])
    assert description == "search_docs - Search support documentation"

    with_args = Renderer.render_text_description_and_args([%SearchDocs{}])
    assert with_args =~ "search_docs - Search support documentation, args:"
    assert with_args =~ "query"
    refute with_args =~ "runtime"
  end
end
