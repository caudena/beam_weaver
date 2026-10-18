# A text-to-SQL agent: it inspects the tables, writes a read-only query, runs
# it, and answers from the result. Rules live in /AGENTS.md and query advice
# in a skill.
#
# The three database tools answer from a small in-memory table, so the
# example runs without a database.
#
#   mix run examples/deepagents/text_to_sql_agent.exs

Code.require_file("support/support.exs", __DIR__)

defmodule BeamWeaver.Examples.DeepAgents.TextToSqlAgent.Db do
  @moduledoc false

  @tables %{
    "customers" => ["customer_id", "name", "country"],
    "invoices" => ["invoice_id", "customer_id", "total"]
  }

  @customers Enum.with_index(
               ~w(Canada Canada Brazil Canada USA Canada Germany Canada Canada France Canada Canada),
               fn country, i -> %{"customer_id" => i + 1, "name" => "Customer #{i + 1}", "country" => country} end
             )

  def tables, do: @tables

  # Understands just enough SQL for the example: a country filter, COUNT, and
  # DISTINCT country, all over the customers table.
  def query(sql) do
    down = String.downcase(sql)
    country = @customers |> Enum.map(& &1["country"]) |> Enum.find(&String.contains?(down, String.downcase(&1)))
    rows = if country, do: Enum.filter(@customers, &(&1["country"] == country)), else: @customers

    cond do
      not String.match?(down, ~r/^\s*select/) -> "Error: only SELECT queries are allowed."
      down =~ "count(" -> JSON.encode!([%{"count" => length(rows)}])
      down =~ "distinct" -> rows |> Enum.map(&%{"country" => &1["country"]}) |> Enum.uniq() |> JSON.encode!()
      true -> JSON.encode!(rows)
    end
  end
end

defmodule BeamWeaver.Examples.DeepAgents.TextToSqlAgent.ListTables do
  use BeamWeaver.Tool

  name "list_tables"
  description "List the tables in the database."

  @impl true
  def invoke(_tool, _input, _opts),
    do: {:ok, BeamWeaver.Examples.DeepAgents.TextToSqlAgent.Db.tables() |> Map.keys() |> Enum.join(", ")}
end

defmodule BeamWeaver.Examples.DeepAgents.TextToSqlAgent.GetSchema do
  use BeamWeaver.Tool

  name "get_schema"
  description "Return the columns of a table."

  schema do
    field :table, :string, description: "The table name"
  end

  @impl true
  def invoke(_tool, %{"table" => table}, _opts) do
    case Map.fetch(BeamWeaver.Examples.DeepAgents.TextToSqlAgent.Db.tables(), table) do
      {:ok, columns} -> {:ok, "#{table}(#{Enum.join(columns, ", ")})"}
      :error -> {:ok, "No table named #{table}."}
    end
  end
end

defmodule BeamWeaver.Examples.DeepAgents.TextToSqlAgent.ExecuteQuery do
  use BeamWeaver.Tool

  name "execute_query"
  description "Run a read-only SQL query and return the rows as JSON."

  schema do
    field :sql, :string, description: "A SELECT statement"
  end

  @impl true
  def invoke(_tool, %{"sql" => sql}, _opts), do: {:ok, BeamWeaver.Examples.DeepAgents.TextToSqlAgent.Db.query(sql)}
end

defmodule BeamWeaver.Examples.DeepAgents.TextToSqlAgent do
  alias BeamWeaver.Agent
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Examples.DeepAgents.Support
  alias BeamWeaver.Examples.DeepAgents.TextToSqlAgent.{ExecuteQuery, GetSchema, ListTables}
  alias BeamWeaver.Filesystem.Local

  def run do
    root = Support.fresh_root!("text_to_sql")
    File.write!(Path.join(root, "AGENTS.md"), "Only run read-only SQL. Check a table's columns before you query it.\n")
    File.mkdir_p!(Path.join(root, "skills/query-writing"))

    File.write!(Path.join(root, "skills/query-writing/SKILL.md"), """
    ---
    name: query-writing
    description: Use when writing SQL queries against the database.
    ---
    List the tables, read the schema of the ones you need, select only the columns you need,
    and answer with the number from the result.
    """)

    {:ok, agent} =
      Support.create(
        name: "text-to-sql",
        model: Support.model(),
        filesystem: Local.new(root: root),
        memory: ["/AGENTS.md"],
        skills: ["/skills"],
        tools: [ListTables, GetSchema, ExecuteQuery]
      )

    {:ok, %{messages: messages}} = Agent.invoke(agent, %{messages: ["How many customers are from Canada?"]})

    IO.puts(Support.assert_text!(List.last(messages)))
    Support.assert_tools_called!(messages, ["execute_query"])
    true = String.match?(Message.text(List.last(messages)), ~r/\b8\b|\beight\b/i)
  end
end

BeamWeaver.Examples.DeepAgents.TextToSqlAgent.run()
