Code.require_file("support/support.exs", __DIR__)

defmodule BeamWeaver.Examples.DeepAgents.NvidiaDeepAgent do
  alias BeamWeaver.Agent
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Filesystem.Local
  alias BeamWeaver.Agent.Subagent.Spec
  alias BeamWeaver.Examples.DeepAgents.Support

  def run do
    root = fresh_root!("nvidia_deep_agent")
    seed_gpu_skills!(root)

    data_processor =
      Spec.new(
        name: "data-processor-agent",
        description: "Writes and runs GPU or CPU data analysis scripts in a sandbox.",
        system_prompt: "Use cuDF/cuML skills when GPU context is available.",
        tools: [run_analysis_tool()],
        skills: ["/skills"],
        model: Support.model("GPU analysis complete with chart artifacts")
      )

    {:ok, agent} =
      Support.create(
        name: "nvidia-deep-agent",
        model: Support.model("nvidia_deep_agent: frontier planner delegated RAPIDS analysis"),
        filesystem: Local.new(root: root),
        skills: ["/skills"],
        tools: [run_analysis_tool()],
        subagents: [data_processor],
        context_schema: %{sandbox_type: %{type: "string", enum: ["gpu", "cpu"]}}
      )

    {:ok, %{messages: messages}} =
      Agent.invoke(agent, %{messages: [Message.user("Analyze 1000 synthetic transactions.")]})

    IO.puts(Message.text(List.last(messages)))
  end

  defp seed_gpu_skills!(root) do
    for {name, description} <- [
          {"cudf-analytics", "Use when performing GPU dataframe analysis with cuDF."},
          {"cuml-machine-learning", "Use when training GPU machine learning models with cuML."},
          {"data-visualization", "Use when creating charts for analysis artifacts."},
          {"gpu-document-processing", "Use when processing large documents in a sandbox."}
        ] do
      dir = Path.join([root, "skills", name])
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "SKILL.md"), """
      ---
      name: #{name}
      description: #{description}
      ---
      Prefer RAPIDS APIs in GPU mode and portable Python fallbacks in CPU mode.
      """)
    end
  end

  defp run_analysis_tool do
    Tool.from_function!(
      name: "run_analysis",
      description: "Run a local stand-in for sandboxed GPU analysis.",
      input_schema: %{
        "type" => "object",
        "properties" => %{"dataset" => %{"type" => "string"}},
        "required" => ["dataset"]
      },
      handler: fn %{"dataset" => dataset}, _opts ->
        "analysis complete for #{dataset}; chart saved to /charts/summary.png"
      end
    )
  end

  defp fresh_root!(name) do
    root = Path.join(System.tmp_dir!(), "beam_weaver_deepagents_#{name}")
    File.rm_rf!(root)
    File.mkdir_p!(root)
    root
  end
end

BeamWeaver.Examples.DeepAgents.NvidiaDeepAgent.run()
