Code.require_file("support/support.exs", __DIR__)

defmodule BeamWeaver.Examples.DeepAgents.TextToSqlAgent do
  alias BeamWeaver.Agent
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Filesystem.Local
  alias BeamWeaver.Examples.DeepAgents.Support

  @schema %{
    "Artist" => ["ArtistId", "Name"],
    "Invoice" => ["InvoiceId", "CustomerId", "Total"],
    "Customer" => ["CustomerId", "Country", "SupportRepId"]
  }

  def run do
    root = fresh_root!("text_to_sql")
    seed_guidance!(root)

    {:ok, agent} =
      Support.create(
        model:
          Support.model(
            "text_to_sql: inspected schema, checked the query, and returned Canada = 8"
          ),
        filesystem: Local.new(root: root),
        memory: ["/AGENTS.md"],
        skills: ["/skills"],
        tools: [list_tables_tool(), get_schema_tool(), execute_query_tool()]
      )

    {:ok, %{messages: messages}} =
      Agent.invoke(agent, %{messages: [Message.user("How many customers are from Canada?")]})

    IO.puts(Message.text(List.last(messages)))
  end

  defp list_tables_tool do
    Tool.from_function!(
      name: "list_tables",
      description: "List available database tables.",
      input_schema: %{"type" => "object", "properties" => %{}},
      handler: fn _input, _opts -> @schema |> Map.keys() |> Enum.sort() |> Enum.join(", ") end
    )
  end

  defp get_schema_tool do
    Tool.from_function!(
      name: "get_schema",
      description: "Return columns for a table.",
      input_schema: %{
        "type" => "object",
        "properties" => %{"table" => %{"type" => "string"}},
        "required" => ["table"]
      },
      handler: fn %{"table" => table}, _opts ->
        "#{table}(#{Enum.join(Map.get(@schema, table, []), ", ")})"
      end
    )
  end

  defp execute_query_tool do
    Tool.from_function!(
      name: "execute_query",
      description: "Execute a safe read-only SQL query against demo data.",
      input_schema: %{
        "type" => "object",
        "properties" => %{"sql" => %{"type" => "string"}},
        "required" => ["sql"]
      },
      handler: fn %{"sql" => sql}, _opts ->
        if String.contains?(String.downcase(sql), "canada"), do: "[{\"count\":8}]", else: "[]"
      end
    )
  end

  defp seed_guidance!(root) do
    File.write!(
      Path.join(root, "AGENTS.md"),
      "Only run read-only SQL. Explain joins before use.\n"
    )

    skill_dir = Path.join([root, "skills", "query-writing"])
    File.mkdir_p!(skill_dir)

    File.write!(Path.join(skill_dir, "SKILL.md"), """
    ---
    name: query-writing
    description: Use when writing SQL queries against the Chinook-style schema.
    ---
    Inspect tables, select only needed columns, and verify row counts.
    """)
  end

  defp fresh_root!(name) do
    root = Path.join(System.tmp_dir!(), "beam_weaver_deepagents_#{name}")
    File.rm_rf!(root)
    File.mkdir_p!(root)
    root
  end
end

BeamWeaver.Examples.DeepAgents.TextToSqlAgent.run()
