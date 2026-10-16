# A data-analysis agent: GPU analytics skills in /skills, and a
# data-processor subagent that runs the analysis. The run context says which
# sandbox to use, and the analysis tool reads it.
#
# `run_analysis` stands in for running a script in a GPU or CPU sandbox; it
# totals a CSV file from the agent's filesystem.
#
#   mix run examples/deepagents/nvidia_deep_agent.exs

Code.require_file("support/support.exs", __DIR__)

defmodule BeamWeaver.Examples.DeepAgents.NvidiaDeepAgent.RunAnalysis do
  use BeamWeaver.Tool

  name "run_analysis"
  description "Run an analysis in the sandbox: total the amount column of a CSV file, grouped by country."

  injected :context, :context

  schema do
    field :dataset, :string, description: "Path of the CSV file, such as /data/sales.csv"
  end

  @impl true
  def invoke(_tool, %{"dataset" => dataset} = input, _opts) do
    sandbox = get_in(input, [:context, :sandbox_type]) || "cpu"
    root = BeamWeaver.Examples.DeepAgents.NvidiaDeepAgent.root()

    with {:ok, relative} <- Path.safe_relative(String.trim_leading(dataset, "/")),
         {:ok, csv} <- File.read(Path.join(root, relative)) do
      totals =
        csv
        |> String.split("\n", trim: true)
        |> Enum.drop(1)
        |> Enum.map(&String.split(&1, ","))
        |> Enum.group_by(fn [_date, country, _amount] -> country end, &String.to_integer(List.last(&1)))
        |> Enum.map_join(", ", fn {country, amounts} -> "#{country} #{Enum.sum(amounts)} EUR" end)

      {:ok, "Ran on the #{sandbox} sandbox. Total amount by country: #{totals}."}
    else
      _error -> {:ok, "No readable CSV file at #{dataset}."}
    end
  end
end

defmodule BeamWeaver.Examples.DeepAgents.NvidiaDeepAgent do
  alias BeamWeaver.Agent
  alias BeamWeaver.Agent.Subagent.Spec
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Examples.DeepAgents.NvidiaDeepAgent.RunAnalysis
  alias BeamWeaver.Examples.DeepAgents.Support
  alias BeamWeaver.Filesystem.Local

  def root, do: Support.root("nvidia_deep_agent")

  def run do
    root = Support.fresh_root!("nvidia_deep_agent")
    seed_data_and_skills!(root)

    data_processor =
      Spec.new(
        name: "data-processor",
        description: "Runs data analysis in a GPU or CPU sandbox and reports the results.",
        system_prompt: "Run the analysis with run_analysis and report the numbers it returns.",
        tools: [RunAnalysis],
        model: Support.model(),
        middleware: Support.limits()
      )

    {:ok, agent} =
      Support.create(
        name: "data-analyst",
        model: Support.model(),
        filesystem: Local.new(root: root),
        skills: ["/skills"],
        subagents: [data_processor],
        context_schema: %{sandbox_type: %{type: "string", enum: ["gpu", "cpu"]}},
        system_prompt: "You plan data analyses. Hand every computation to the data-processor subagent."
      )

    {:ok, %{messages: messages}} =
      Agent.invoke(
        agent,
        %{messages: ["What were total sales by country in /data/transactions.csv?"]},
        context: %{sandbox_type: "cpu"}
      )

    IO.puts(Message.text(List.last(messages)))
    Support.assert_tools_called!(messages, ["task"])
  end

  defp seed_data_and_skills!(root) do
    File.mkdir_p!(Path.join(root, "data"))

    File.write!(Path.join(root, "data/transactions.csv"), """
    date,country,amount
    2026-09-01,Portugal,120
    2026-09-01,Spain,80
    2026-09-02,Portugal,45
    2026-09-02,France,200
    2026-09-03,Spain,60
    2026-09-03,Portugal,300
    """)

    for {name, description} <- [
          {"cudf-analytics", "Use for dataframe analysis (group-by, joins, aggregates) on the GPU with cuDF."},
          {"cuml-machine-learning", "Use when training machine learning models on the GPU with cuML."},
          {"data-visualization", "Use when creating charts for analysis results."}
        ] do
      dir = Path.join([root, "skills", name])
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "SKILL.md"), """
      ---
      name: #{name}
      description: #{description}
      ---
      Prefer RAPIDS APIs on a GPU sandbox and pandas on a CPU sandbox.
      """)
    end
  end
end

BeamWeaver.Examples.DeepAgents.NvidiaDeepAgent.run()
