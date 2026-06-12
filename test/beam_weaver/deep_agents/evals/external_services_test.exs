defmodule BeamWeaver.DeepAgents.Evals.ExternalServicesTest do
  use ExUnit.Case, async: false

  alias BeamWeaver.TestSupport.DeepAgents.Evals.{Harbor, HarborSandbox, Metadata}

  test "Harbor eval helpers stay behind optional boundaries" do
    refute Harbor.enabled?()

    metadata = Metadata.collect()
    assert metadata.host["elixir_version"] == System.version()
    assert metadata.sandbox == %{"enabled" => false}

    sandbox = HarborSandbox.new()

    assert %BeamWeaver.Filesystem.Executable.ExecuteResult{error: "missing_sandbox"} =
             BeamWeaver.Filesystem.Executable.execute(sandbox, "echo hi")
  end
end
