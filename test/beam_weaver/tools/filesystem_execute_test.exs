defmodule BeamWeaver.Tools.FilesystemExecuteTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.Middleware
  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Filesystem.LocalShell
  alias BeamWeaver.Tools.Filesystem, as: FilesystemTools

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    execute =
      [root: dir]
      |> LocalShell.new()
      |> FilesystemTools.tools()
      |> Enum.find(&(Tool.name(&1) == "execute"))

    %{execute: execute}
  end

  test "execute returns the command's output and its exit code", %{execute: execute} do
    assert {:ok, "hi\n[Command succeeded with exit code 0]"} =
             Tool.invoke(execute, %{"command" => "printf 'hi\\n'"})

    assert {:ok, "partial\n[Command failed with exit code 2]"} =
             Tool.invoke(execute, %{"command" => "printf partial; exit 2"})

    assert {:ok, "[Command failed with exit code 1]"} = Tool.invoke(execute, %{"command" => "false"})
  end

  test "execute tells the model when a command timed out", %{execute: execute} do
    assert {:ok, "Error: the command timed out after 1 second and was stopped." <> hint} =
             Tool.invoke(execute, %{"command" => "sleep 5", "timeout" => 1})

    assert hint =~ "larger `timeout`"
  end

  test "the filesystem prompt describes what execute returns", %{tmp_dir: dir} do
    middleware = Middleware.Filesystem.new(backend: LocalShell.new(root: dir))

    assert %ModelRequest{system_message: %Message{content: prompt}} =
             Middleware.Filesystem.wrap_model_call(middleware, ModelRequest.new(system_prompt: "base"), & &1)

    assert prompt =~ "followed by a line with its exit code"
    assert prompt =~ "is stopped and returns an error"
  end
end
