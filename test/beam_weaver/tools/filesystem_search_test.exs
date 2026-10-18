defmodule BeamWeaver.Tools.FilesystemSearchTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Filesystem.LocalShell
  alias BeamWeaver.Filesystem.Permission
  alias BeamWeaver.Filesystem.State
  alias BeamWeaver.Models.FakeChatModel
  alias BeamWeaver.Tools.Filesystem, as: FilesystemTools

  @moduletag :tmp_dir

  @regex_note "Note: grep matches literal text, not regex, so characters like `|`, `.*` and `\\.` " <>
                "are searched as they are. Search for the literal text instead; for `|`, " <>
                "run a separate search for each alternative."

  @rg_line "For a real regex, use execute with `rg '<regex>'`."

  defp tool(backend \\ State.new(), name, permissions \\ []) do
    backend |> FilesystemTools.tools(permissions: permissions) |> Enum.find(&(Tool.name(&1) == name))
  end

  defp invoke(tool, args, files), do: Tool.invoke(tool, Map.put(args, :state, %{files: files}))

  describe "a grep that finds nothing" do
    setup do
      %{files: %{"/app/user.ex" => "def init(self) do\n  self.tools = arr[0]\nend\n"}}
    end

    test "says grep is literal when the pattern looks like a regex", %{files: files} do
      for pattern <- ["init|start", "def .*init", "self.+tools", "user\\.ex", "\\w+", "\\d", "\\(", "\\$", "\\|"] do
        assert {:ok, "[]\n\n" <> note} = invoke(tool("grep"), %{"pattern" => pattern}, files), pattern
        assert note == @regex_note
      end
    end

    test "says nothing more for literal code searches", %{files: files} do
      for pattern <- ["self.toolz", "arr[1]", "def init(self):", "what?", "^start", "end$", "a.b", "(x)"] do
        assert {:ok, "[]"} = invoke(tool("grep"), %{"pattern" => pattern}, files), pattern
      end
    end

    test "says nothing more when the pattern matched literally" do
      files = %{"/app/flags.ex" => "mode = a|b\n"}

      assert {:ok, json} = invoke(tool("grep"), %{"pattern" => "a|b"}, files)
      assert [%{"path" => "/app/flags.ex", "text" => "mode = a|b"}] = JSON.decode!(json)
    end

    test "says nothing more when the matches were all hidden by permissions" do
      files = %{"/secrets/key.txt" => "token|secret\n"}
      grep = tool(State.new(), "grep", [Permission.new(paths: ["/secrets/**"], mode: :deny)])

      assert {:ok, "[]"} = invoke(grep, %{"pattern" => "token|secret"}, files)
    end
  end

  describe "grep's description" do
    test "says the pattern is literal text and to run one grep for each string" do
      description = Tool.description(tool("grep"))

      assert description =~ "literal text, not a regex"
      assert description =~ "run one grep for each"
      refute description =~ "execute"
    end

    test "points to execute for a real regex when the backend runs commands", %{tmp_dir: dir} do
      assert Tool.description(tool(LocalShell.new(root: dir), "grep")) =~ @rg_line
    end

    test "points to execute only while the model is offered execute", %{tmp_dir: dir} do
      assert grep_description_sent(filesystem: LocalShell.new(root: dir)) =~ @rg_line
      refute grep_description_sent(filesystem: LocalShell.new(root: dir), exclude_tools: ["execute"]) =~ "execute"
      refute grep_description_sent(filesystem: State.new()) =~ "execute"
    end

    test "keeps a description set with tool_descriptions", %{tmp_dir: dir} do
      assert grep_description_sent(
               filesystem: LocalShell.new(root: dir),
               exclude_tools: ["execute"],
               tool_descriptions: %{"grep" => "Search the knowledge base."}
             ) == "Search the knowledge base."
    end
  end

  defp grep_description_sent(opts) do
    {:ok, agent} = Agent.build([model: %FakeChatModel{responses: ["ok"], parent: self()}] ++ opts)
    assert {:ok, _state} = Agent.invoke(agent, %{messages: ["hi"]})
    assert_received {:fake_chat_model_call, _messages, model_opts}

    model_opts |> Keyword.fetch!(:tools) |> Enum.find(&(Tool.name(&1) == "grep")) |> Tool.description()
  end

  describe "a search denied by the permissions" do
    setup do
      rules = [Permission.new(paths: ["/src/**"]), Permission.new(paths: ["/**"], mode: :deny)]

      %{
        glob: tool(State.new(), "glob", rules),
        grep: tool(State.new(), "grep", rules),
        files: %{"/src/app/main.py" => "print(1)\n"}
      }
    end

    test "without a path says the check was against / and how to retry", %{glob: glob, files: files} do
      assert {:ok,
              "Error: Permission denied reading /. A glob without `path` is checked against /, " <>
                "not the directories in `pattern`. Retry with a `path` inside an allowed directory " <>
                "and a `pattern` relative to it."} = invoke(glob, %{"pattern" => "/src/**/*.py"}, files)
    end

    test "with a path keeps the plain error", %{glob: glob, files: files} do
      assert {:ok, "Error: Permission denied reading /"} =
               invoke(glob, %{"pattern" => "/src/**/*.py", "path" => "/"}, files)

      assert {:ok, json} = invoke(glob, %{"pattern" => "**/*.py", "path" => "/src"}, files)
      assert [%{"path" => "/src/app/main.py"}] = JSON.decode!(json)
    end

    test "a grep without a path says the check was against / and how to retry", %{grep: grep, files: files} do
      assert {:ok, "Error: Permission denied reading /. A grep without `path` is checked against /. " <> retry} =
               invoke(grep, %{"pattern" => "print", "glob" => "src/**/*.py"}, files)

      assert retry == "Retry with a `path` inside an allowed directory."

      assert {:ok, "Error: Permission denied reading /"} = invoke(grep, %{"pattern" => "print", "path" => "/"}, files)
      assert {:ok, json} = invoke(grep, %{"pattern" => "print", "path" => "/src"}, files)
      assert [%{"path" => "/src/app/main.py"}] = JSON.decode!(json)
    end
  end
end
