defmodule BeamWeaver.Tool.SchemaLikeTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Tool.Schema

  defmodule FakeEctoSchema do
    defstruct [:id, :title, :views, :tags, :published_at, :metadata]

    def __schema__(:fields), do: [:id, :title, :views, :tags, :published_at, :metadata]
    def __schema__(:type, :id), do: :binary_id
    def __schema__(:type, :title), do: :string
    def __schema__(:type, :views), do: :integer
    def __schema__(:type, :tags), do: {:array, :string}
    def __schema__(:type, :published_at), do: :utc_datetime
    def __schema__(:type, :metadata), do: :map
  end

  defmodule ExplicitSchema do
    def __beam_weaver_schema__ do
      [
        {:query, :string, required: true, description: "Search query"},
        {:limit, :integer, required: false, default: 5}
      ]
    end
  end

  test "converts explicit field declarations through SchemaLike" do
    assert {:ok, schema} =
             Schema.from([
               {:query, :string, description: "Search query"},
               {:limit, :integer, required: false, default: 5},
               {:value, {:union, [:integer, :string]}},
               {:filters, {:object, [{:kind, :string, required: false}]}, required: false}
             ])

    assert schema.type == "object"
    assert schema.required == [:query, :value]
    assert schema.properties.query.description == "Search query"
    assert schema.properties.limit.default == 5
    assert schema.properties.value.anyOf == [%{type: "integer"}, %{type: "string"}]
    assert schema.properties.filters.properties.kind.type == "string"
  end

  test "converts NimbleOptions-style specs without treating them as field tuples" do
    assert {:ok, schema} =
             Schema.from(
               query: [type: :string, required: true, doc: "Search query"],
               limit: [type: :integer, default: 10],
               mode: [type: :string, values: ["fast", "deep"]]
             )

    assert schema.required == [:query]
    assert schema.properties.query.description == "Search query"
    assert schema.properties.limit.default == 10
    assert schema.properties.mode.enum == ["fast", "deep"]
  end

  test "converts Ecto-style schema modules and structs without depending on Ecto at runtime" do
    assert {:ok, schema} = Schema.from(FakeEctoSchema)
    assert schema.required == []
    assert schema.properties.id.type == "string"
    assert schema.properties.title.type == "string"
    assert schema.properties.views.type == "integer"
    assert schema.properties.tags.items.type == "string"
    assert schema.properties.published_at.format == "date-time"
    assert schema.properties.metadata.type == "object"

    assert {:ok, struct_schema} = Schema.from(%FakeEctoSchema{})
    assert struct_schema == schema
  end

  test "converts explicit schema modules before falling back to Ecto-style introspection" do
    assert {:ok, schema} = Schema.from(ExplicitSchema)
    assert schema.required == [:query]
    assert schema.properties.query.description == "Search query"
    assert schema.properties.limit.default == 5
  end

  test "passes JSON schema maps through as plain string-keyed data" do
    assert {:ok, schema} =
             Schema.from(%{
               type: :object,
               properties: %{query: %{type: :string}},
               required: [:query]
             })

    assert schema == %{
             "type" => "object",
             "properties" => %{"query" => %{"type" => "string"}},
             "required" => ["query"]
           }
  end

  test "removes schema title annotations without removing title fields" do
    schema = %{
      "type" => "object",
      "title" => "Root",
      "properties" => %{
        "people" => %{
          "title" => "People",
          "type" => "array",
          "items" => %{
            "title" => "Person",
            "type" => "object",
            "properties" => %{
              "name" => %{"title" => "Name", "type" => "string"},
              "title" => %{"title" => "Title", "type" => "string"}
            }
          }
        }
      }
    }

    assert Schema.remove_titles(schema) == %{
             "type" => "object",
             "properties" => %{
               "people" => %{
                 "type" => "array",
                 "items" => %{
                   "type" => "object",
                   "properties" => %{
                     "name" => %{"type" => "string"},
                     "title" => %{"type" => "string"}
                   }
                 }
               }
             }
           }
  end

  test "dereferences local JSON schema refs with cycles, lists, and mixed overrides" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "user" => %{"$ref" => "#/$defs/User"},
        "payload" => %{
          "anyOf" => [
            %{"type" => "string"},
            %{
              "type" => "object",
              "properties" => %{
                "startDate" => %{"type" => "string", "pattern" => "^\\\\d{4}"},
                "endDate" => %{"$ref" => "#/properties/payload/anyOf/1/properties/startDate"}
              }
            }
          ]
        },
        "overridden" => %{
          "$ref" => "#/$defs/Base",
          "type" => "number",
          "description" => "Overridden"
        },
        "integer_key" => %{"$ref" => "#/$defs/400"}
      },
      "$defs" => %{
        "User" => %{
          "type" => "object",
          "properties" => %{
            "id" => %{"type" => "string"},
            "parent" => %{"$ref" => "#/$defs/User", "nullable" => true}
          }
        },
        "Base" => %{"type" => "string", "description" => "Original"},
        400 => %{"type" => "object", "properties" => %{"description" => "Bad Request"}}
      }
    }

    assert {:ok, dereferenced} = Schema.dereference_refs(schema)

    assert dereferenced["properties"]["user"] == %{
             "type" => "object",
             "properties" => %{
               "id" => %{"type" => "string"},
               "parent" => %{"nullable" => true}
             }
           }

    assert dereferenced["properties"]["payload"]["anyOf"] == [
             %{"type" => "string"},
             %{
               "type" => "object",
               "properties" => %{
                 "startDate" => %{"type" => "string", "pattern" => "^\\\\d{4}"},
                 "endDate" => %{"type" => "string", "pattern" => "^\\\\d{4}"}
               }
             }
           ]

    assert dereferenced["properties"]["overridden"] == %{
             "type" => "number",
             "description" => "Overridden"
           }

    assert dereferenced["properties"]["integer_key"] == %{
             "type" => "object",
             "properties" => %{"description" => "Bad Request"}
           }

    assert dereferenced["$defs"]["User"]["properties"]["parent"] == %{
             "$ref" => "#/$defs/User",
             "nullable" => true
           }

    assert {:ok, dereferenced_defs} = Schema.dereference_refs(schema, skip_keys: [])

    assert dereferenced_defs["$defs"]["User"]["properties"]["parent"] == %{
             "type" => "object",
             "properties" => %{
               "id" => %{"type" => "string"},
               "parent" => %{"nullable" => true}
             },
             "nullable" => true
           }
  end

  test "dereference_refs returns tagged errors for remote or missing refs" do
    assert {:error, %Error{type: :invalid_json_schema_ref}} =
             Schema.dereference_refs(%{"broken" => %{"$ref" => "https://example.com/ref"}})

    assert {:error, %Error{type: :json_schema_ref_not_found}} =
             Schema.dereference_refs(%{
               "properties" => %{"value" => %{"$ref" => "#/missing/0"}}
             })

    assert {:error, %Error{type: :json_schema_ref_not_found}} =
             Schema.dereference_refs(%{
               "items" => [%{"type" => "string"}],
               "bad" => %{"$ref" => "#/items/-1"}
             })
  end

  test "returns tagged errors for unsupported schema-like values" do
    assert {:error, %Error{type: :invalid_tool_schema}} = Schema.from(self())

    assert {:error, %Error{type: :invalid_tool_schema}} =
             Schema.from([{:query, :string, []}, :not_a_field])
  end
end
