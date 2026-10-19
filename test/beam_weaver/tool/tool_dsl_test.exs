defmodule BeamWeaver.Tool.DSLTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Core.ToolResult
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

  defmodule FilterOrders do
    use BeamWeaver.Tool

    name("filter_orders")
    description("Filter orders by status, tag and date range")

    schema do
      field(:filters, :object,
        nullable: true,
        properties: %{status: %{type: "string", enum: ["open", "shipped"]}, limit: %{type: "integer", maximum: 50}}
      )

      field(:region, %{type: "object", properties: %{code: %{type: "string"}}, additionalProperties: false},
        required: false,
        nullable: true
      )

      field(:tags, :array, required: false, nullable: true, items: %{type: "string", maxLength: 8})
      field(:range, {:object, [{:from, :date}, {:to, :date, required: false}]}, required: false, nullable: true)
      field(:priority, :string, required: false, nullable: true, enum: ["low", "high"])
    end

    @impl true
    def invoke(_tool, input, _opts), do: {:ok, input}
  end

  defmodule DirectTool do
    use BeamWeaver.Core.Tool

    defstruct []

    def name(_tool), do: "direct_tool"
    def description(_tool), do: "Direct behaviour tool"

    def input_schema(_tool),
      do: %{type: "object", properties: %{value: %{type: "string"}}, required: [:value]}

    def injected(_tool), do: %{}
    def return_direct(_tool), do: false
    def invoke(_tool, input, _opts), do: {:ok, String.upcase(input.value)}
  end

  # Its schema is built from the struct, which the DSL can't declare.
  defmodule SectionSearch do
    use BeamWeaver.Core.Tool

    defstruct sections: ["billing", "shipping", "returns"]

    @impl true
    def name(_tool), do: "search_section"

    @impl true
    def description(_tool), do: "Search one section of the help center."

    @impl true
    def input_schema(%__MODULE__{sections: sections}) do
      %{
        "type" => "object",
        "properties" => %{"query" => %{"type" => "string"}, "section" => %{"type" => "string", "enum" => sections}},
        "required" => ["query", "section"]
      }
    end

    @impl true
    def invoke(_tool, %{"query" => query, "section" => section}, _opts), do: {:ok, "#{section}: #{query}"}
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

    assert {:ok, %ToolResult{content: %{query: "refunds", limit: 5}, artifact: nil}} =
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

  test "a nullable object or array field accepts nil and validates any other value" do
    schema = Tool.input_schema(%FilterOrders{})

    assert :ok = Tool.validate_input(schema, %{filters: nil, region: nil, tags: nil, range: nil})

    assert {:ok, %{"filters" => %{"status" => "open", "limit" => 10}, "range" => %{"from" => "2026-10-01"}}} =
             Tool.normalize_input(schema, %{
               filters: %{status: "open", limit: 10},
               region: %{code: "eu"},
               tags: ["rush"],
               range: %{from: "2026-10-01"}
             })

    for {input, message} <- [
          {%{filters: %{status: "lost"}}, "tool input is not in enum"},
          {%{filters: %{limit: 51}}, "number is too large"},
          {%{filters: nil, region: %{code: "eu", zone: "west"}}, "tool input contains unknown keys"},
          {%{filters: nil, tags: ["much-too-long"]}, "string is too long"},
          {%{filters: nil, range: %{to: "2026-10-31"}}, "tool input is missing required keys"}
        ] do
      assert {:error, %{type: :invalid_input, message: ^message}} = Tool.validate_input(schema, input)
    end
  end

  test "a nullable enum field lists nil among its values and accepts it" do
    schema = Tool.input_schema(%FilterOrders{})

    assert schema.properties["priority"].enum == ["low", "high", nil]
    assert :ok = Tool.validate_input(schema, %{filters: nil, priority: nil})

    assert {:error, %{message: "tool input is not in enum"}} =
             Tool.validate_input(schema, %{filters: nil, priority: "urgent"})
  end

  test "provider tool schemas keep nil in a nullable field's enum" do
    messages = [BeamWeaver.Core.Message.user("List open orders.")]

    bodies =
      for module <- [
            BeamWeaver.OpenAI.ChatModel,
            BeamWeaver.OpenAI.ChatCompletionsModel,
            BeamWeaver.Anthropic.ChatModel,
            BeamWeaver.Google.ChatModel,
            BeamWeaver.XAI.ChatModel,
            BeamWeaver.XAI.ChatCompletionsModel
          ] do
        assert {:ok, body} = module.request_body(module.new([]), messages, tools: [FilterOrders])
        {module, body["tools"]}
      end

    strict = [
      {:openai_strict, BeamWeaver.OpenAI.ToolCalling.function(%FilterOrders{}, strict: true)},
      {:anthropic_strict, BeamWeaver.Anthropic.Tools.function(%FilterOrders{}, strict: true)}
    ]

    for {renderer, rendered} <- bodies ++ strict do
      assert priority_enums(rendered) == [["low", "high", nil]], inspect(renderer)
    end
  end

  test "direct behaviour modules work without the macro" do
    assert {:ok, "ADA"} = Tool.invoke(%DirectTool{}, %{value: "ada"})
    assert Tool.input_schema(%DirectTool{}).required == [:value]
  end

  test "use BeamWeaver.Core.Tool defaults the optional callbacks and takes a computed schema" do
    search = %SectionSearch{sections: ["billing", "returns"]}

    assert {:ok, "billing: refund"} = Tool.invoke(search, %{"query" => "refund", "section" => "billing"})
    assert {:error, %{type: :invalid_input}} = Tool.invoke(search, %{"query" => "refund", "section" => "shipping"})
    assert Tool.input_schema(search)["properties"]["section"]["enum"] == ["billing", "returns"]

    assert {Tool.injected(search), Tool.return_direct(search), Tool.concurrent?(search)} == {%{}, false, true}
    assert {Tool.max_result_chars(search), Tool.tags(search), Tool.metadata(search)} == {:unlimited, [], %{}}
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

  defp priority_enums(%{"properties" => %{"priority" => %{"enum" => enum}}}), do: [enum]
  defp priority_enums(%{} = map), do: Enum.flat_map(Map.values(map), &priority_enums/1)
  defp priority_enums(list) when is_list(list), do: Enum.flat_map(list, &priority_enums/1)
  defp priority_enums(_value), do: []
end
