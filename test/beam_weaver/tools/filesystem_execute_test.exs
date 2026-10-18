defmodule BeamWeaver.Tools.FilesystemExecuteTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent
  alias BeamWeaver.Agent.Middleware
  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Filesystem.Executable.ExecuteResult
  alias BeamWeaver.Filesystem.LocalShell
  alias BeamWeaver.Models.FakeChatModel
  alias BeamWeaver.Tools.Filesystem, as: FilesystemTools

  @moduletag :tmp_dir

  # Runs no command: answers every call with the result it was given.
  defmodule CannedShell do
    use BeamWeaver.Filesystem.Executable

    defstruct [:result]

    @impl true
    def id(_shell), do: "canned"

    @impl true
    def execute(%__MODULE__{result: result}, _command, _opts), do: result
  end

  setup %{tmp_dir: dir} do
    %{execute: execute_tool(LocalShell.new(root: dir))}
  end

  defp execute_tool(backend), do: backend |> FilesystemTools.tools() |> Enum.find(&(Tool.name(&1) == "execute"))

  test "execute returns the command's output and its exit code", %{execute: execute} do
    for {command, text, exit_code} <- [
          {"printf 'hi\\n'", "hi\n[Command succeeded with exit code 0]", 0},
          {"printf partial; exit 2", "partial\n[Command failed with exit code 2]", 2},
          {"false", "[Command failed with exit code 1]", 1}
        ] do
      assert {:ok, %Message{role: :tool, name: "execute", metadata: metadata} = message} =
               Tool.invoke(execute, %{"command" => command})

      assert Message.text(message) == text
      assert metadata == %{status: "success", exit_code: exit_code}
    end
  end

  test "execute leaves the exit code out of the metadata when it is unknown" do
    execute = execute_tool(%CannedShell{result: %ExecuteResult{output: "done\n", exit_code: nil}})

    assert {:ok, %Message{metadata: %{status: "success"} = metadata} = message} =
             Tool.invoke(execute, %{"command" => "anything"})

    refute Map.has_key?(metadata, :exit_code)
    assert Message.text(message) == "done\n[Command finished without an exit code]"
  end

  test "execute answers with the error alone when no command ran" do
    execute = execute_tool(%CannedShell{result: %ExecuteResult{error: "sandbox unavailable", exit_code: nil}})

    assert {:ok, "Error: sandbox unavailable"} = Tool.invoke(execute, %{"command" => "anything"})
  end

  test "execute tells the model when a command timed out", %{execute: execute} do
    assert {:ok, "Error: the command timed out after 1 second and was stopped." <> hint} =
             Tool.invoke(execute, %{"command" => "sleep 5", "timeout" => 1})

    assert hint =~ "larger `timeout`"
  end

  test "an agent's execute message carries the exit code and stays a success", %{tmp_dir: dir} do
    model = %FakeChatModel{
      responses: [FakeChatModel.tool_call("execute", %{"command" => "printf nope; exit 3"}), "It failed."]
    }

    {:ok, agent} = Agent.build(model: model, filesystem: LocalShell.new(root: dir))
    assert {:ok, %{messages: messages}} = Agent.invoke(agent, %{messages: ["Run it"]})

    assert %Message{tool_calls: [%{id: call_id}]} = Enum.find(messages, &(&1.role == :assistant))
    tool_message = Enum.find(messages, &(&1.role == :tool))

    assert %Message{tool_call_id: ^call_id, name: "execute", status: nil} = tool_message
    assert tool_message.metadata == %{status: "success", exit_code: 3}
    assert Message.text(tool_message) == "nope\n[Command failed with exit code 3]"
  end

  test "an execute result moved into a file keeps its exit code", %{tmp_dir: dir} do
    command = "head -c 90000 /dev/zero | tr '\\0' x; exit 4"
    model = %FakeChatModel{responses: [FakeChatModel.tool_call("execute", %{"command" => command}), "Done."]}

    {:ok, agent} = Agent.build(model: model, filesystem: LocalShell.new(root: dir))
    assert {:ok, %{messages: messages}} = Agent.invoke(agent, %{messages: ["Run it"]})

    tool_message = Enum.find(messages, &(&1.role == :tool))
    assert Message.text(tool_message) =~ "Tool result too large"
    assert tool_message.metadata.exit_code == 4
  end

  test "the filesystem prompt describes what execute returns", %{tmp_dir: dir} do
    middleware = Middleware.Filesystem.new(backend: LocalShell.new(root: dir))
    request = ModelRequest.new(system_prompt: "base", tools: Middleware.Filesystem.tools(middleware))

    assert %ModelRequest{system_message: %Message{content: prompt}} =
             Middleware.Filesystem.wrap_model_call(middleware, request, & &1)

    assert prompt =~ "followed by a line with its exit code"
    assert prompt =~ "is stopped and returns an error"
  end
end
