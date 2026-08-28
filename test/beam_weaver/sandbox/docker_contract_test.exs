defmodule BeamWeaver.Sandbox.DockerContractTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Sandbox.Docker

  test "durable exec requires the caller to retain an already-started sandbox" do
    assert {:error, "container_not_started"} = Docker.start_exec(Docker.new(), "printf ok")
  end

  test "owned cleanup rejects an empty or malformed identity before Docker I/O" do
    sandbox = Docker.new(container: "not-inspected")

    assert {:error, "invalid_docker_container_identity"} = Docker.stop_owned(sandbox, %{})

    assert {:error, "invalid_docker_container_identity"} =
             Docker.stop_owned(sandbox, %{[] => "invalid"})
  end
end
