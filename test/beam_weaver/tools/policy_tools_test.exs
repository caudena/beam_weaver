defmodule BeamWeaver.Tools.PolicyToolsTest do
  use ExUnit.Case, async: true

  # Upstream reference:

  alias BeamWeaver.Agent.Middleware.ShellTool
  alias BeamWeaver.Core.Document
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Graph.Nodes.ToolNode
  alias BeamWeaver.Models.FakeEmbeddingModel
  alias BeamWeaver.ShellPolicy
  alias BeamWeaver.Tools.FileSearch
  alias BeamWeaver.Tools.Shell
  alias BeamWeaver.Tools.Todo
  alias BeamWeaver.VectorStore
  alias BeamWeaver.VectorStore.ETS, as: ETSVectorStore

  test "shell policy validates execution controls" do
    # Upstream reference:
    assert {:error,
            %{
              type: :invalid_shell_policy,
              message: "shell policy requires at least one allow rule"
            }} =
             ShellPolicy.new([])

    assert {:error, %{type: :invalid_shell_policy, message: "max_output_bytes must be a positive integer"}} =
             ShellPolicy.new(allow: ["echo "], max_output_bytes: 0)

    assert {:error,
            %{
              type: :invalid_shell_policy,
              message: "timeout must be nil, :infinity, or a non-negative integer"
            }} =
             ShellPolicy.new(allow: ["echo "], timeout: -1)

    assert {:error,
            %{
              type: :invalid_shell_policy,
              message: "stderr must be :merge, :separate, or :discard"
            }} =
             ShellPolicy.new(allow: ["echo "], stderr: :invalid)

    assert {:error,
            %{
              type: :invalid_shell_policy,
              message: "redactions must be {regex, replacement} pairs"
            }} =
             ShellPolicy.new(allow: ["echo "], redactions: [{"secret", "[x]"}])

    assert {:ok, policy} = ShellPolicy.new(allow: ["echo "], deny: [~r/secret/])
    assert ShellPolicy.allowed?(policy, "echo hello")
    refute ShellPolicy.allowed?(policy, "echo secret")
  end

  test "shell tool rejects unsafe commands before execution" do
    shell = Shell.new(policy: ShellPolicy.new!(allow: ["echo "]))

    assert {:error, error} = Tool.invoke(shell, %{"command" => "rm -rf /"})
    assert error.type == :shell_command_rejected
  end

  test "shell tool executes an explicitly allowed command" do
    shell = Shell.new(policy: ShellPolicy.new!(allow: ["echo "], max_output_bytes: 100))

    assert {:ok, %{status: 0, output: output}} = Tool.invoke(shell, %{"command" => "echo hello"})
    assert output =~ "hello"
  end

  test "shell tool validates command input and surfaces exit status" do
    shell =
      Shell.new(policy: ShellPolicy.new!(allow: ["false", "printf "], max_output_bytes: 100))

    assert {:error, %{type: :invalid_shell_command}} = Tool.invoke(shell, %{"command" => ""})
    assert {:error, %{type: :invalid_input}} = Tool.invoke(shell, %{"command" => 123})
    assert {:error, %{type: :invalid_input}} = Tool.invoke(shell, %{})

    assert {:ok, %{status: 1, output: ""}} = Tool.invoke(shell, %{"command" => "false"})

    node = ToolNode.new([shell])

    command =
      ToolNode.invoke(node, %{
        messages: [
          Message.assistant("",
            tool_calls: [
              %{id: "call-shell", name: "shell", args: %{"command" => "printf ok"}}
            ]
          )
        ]
      })

    assert %{messages: [%Message{role: :tool, tool_call_id: "call-shell", name: "shell"} = msg]} =
             command

    assert msg.metadata.status == "success"
    assert msg.content =~ "ok"
  end

  test "shell host executor applies cwd env allowlist timeout and output truncation" do
    tmp = Path.join(System.tmp_dir!(), "beam_weaver_shell_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    File.write!(Path.join(tmp, "marker.txt"), "from-cwd")

    shell =
      Shell.new(
        policy:
          ShellPolicy.new!(
            allow: ["pwd", "cat ", "printf ", "sleep "],
            cwd: tmp,
            env: %{"VISIBLE" => "yes", "HIDDEN" => "no"},
            env_allowlist: ["VISIBLE"],
            timeout: 200,
            max_output_bytes: 4
          )
      )

    assert {:ok, %{output: output}} = Tool.invoke(shell, %{"command" => "pwd"})
    assert byte_size(output) == 4

    assert {:ok, %{output: "from"}} = Tool.invoke(shell, %{"command" => "cat marker.txt"})

    assert {:ok, %{output: "yes\n"}} =
             Tool.invoke(shell, %{"command" => "printf \"$VISIBLE\\n\""})

    assert {:ok, %{output: "\n"}} = Tool.invoke(shell, %{"command" => "printf \"$HIDDEN\\n\""})

    assert {:error, %{type: :shell_timeout}} = Tool.invoke(shell, %{"command" => "sleep 1"})
  end

  test "shell host executor applies stderr policies" do
    separate =
      Shell.new(
        policy:
          ShellPolicy.new!(
            allow: ["printf "],
            stderr: :separate,
            max_output_bytes: 20
          )
      )

    assert {:ok, %{output: "out", stderr: "err"}} =
             Tool.invoke(separate, %{"command" => "printf out; printf err >&2"})

    discard =
      Shell.new(
        policy:
          ShellPolicy.new!(
            allow: ["printf "],
            stderr: :discard,
            max_output_bytes: 20
          )
      )

    assert {:ok, %{output: "out"} = result} =
             Tool.invoke(discard, %{"command" => "printf out; printf err >&2"})

    refute Map.has_key?(result, :stderr)

    merge =
      Shell.new(
        policy:
          ShellPolicy.new!(
            allow: ["printf "],
            stderr: :merge,
            max_output_bytes: 20
          )
      )

    assert {:ok, %{output: merged}} =
             Tool.invoke(merge, %{"command" => "printf out; printf err >&2"})

    assert merged =~ "out"
    assert merged =~ "err"
  end

  test "shell host executor formats empty, redacted, and truncated output by policy" do
    shell =
      Shell.new(
        policy:
          ShellPolicy.new!(
            allow: ["printf ", "true"],
            max_output_bytes: 40,
            empty_output: "(no output)",
            redactions: [{~r/user@example.com/, "[REDACTED_EMAIL]"}],
            truncation_indicator: "\n[truncated]"
          )
      )

    assert {:ok, %{output: "(no output)"}} = Tool.invoke(shell, %{"command" => "true"})

    assert {:ok, %{output: output}} =
             Tool.invoke(shell, %{"command" => "printf 'Contact user@example.com'"})

    assert output =~ "[REDACTED"
    refute output =~ "user@example.com"

    assert {:ok, %{output: output}} =
             Tool.invoke(shell, %{
               "command" => "printf 'abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz'"
             })

    assert output == "abcdefghijklmnopqrstuvwxyzabcdefghijklmn\n[truncated]"
  end

  test "shell middleware owns a persistent session with startup restart and shutdown" do
    tmp =
      Path.join(System.tmp_dir!(), "beam_weaver_shell_mw_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    expected_suffix = Path.join(Path.basename(tmp), "nested")

    middleware =
      ShellTool.new(
        workspace_root: tmp,
        startup_commands: ["mkdir -p nested", "cd nested", "export BW_MARKER=ready"],
        shutdown_commands: "printf done > ../shutdown.txt",
        policy:
          ShellPolicy.new!(
            allow: [~r/.*/],
            max_output_bytes: 1_000,
            stderr: :separate
          )
      )

    assert %{shell_session: pid} =
             middleware
             |> ShellTool.async_before_agent(%{}, nil)
             |> Task.await()

    [tool] = ShellTool.tools(middleware)
    state_arg = %{shell_session: pid}

    assert {:ok, %{output: cwd}} =
             Tool.invoke(tool, %{"command" => "pwd", __beam_weaver_shell_state: state_arg})

    assert String.ends_with?(String.trim(cwd), expected_suffix)

    assert {:ok, %{output: "ready"}} =
             Tool.invoke(tool, %{
               "command" => "printf \"$BW_MARKER\"",
               __beam_weaver_shell_state: state_arg
             })

    assert {:ok, %{output: "err", stderr: "warn"}} =
             Tool.invoke(tool, %{
               "command" => "printf err; printf warn >&2",
               __beam_weaver_shell_state: state_arg
             })

    assert {:ok, %{output: "Shell session restarted."}} =
             Tool.invoke(tool, %{"restart" => true, __beam_weaver_shell_state: state_arg})

    assert {:ok, %{output: cwd_after_restart}} =
             Tool.invoke(tool, %{"command" => "pwd", __beam_weaver_shell_state: state_arg})

    assert String.ends_with?(String.trim(cwd_after_restart), expected_suffix)

    assert %{shell_session: nil} =
             middleware
             |> ShellTool.async_after_agent(%{shell_session: pid}, nil)
             |> Task.await()

    assert File.read!(Path.join(tmp, "shutdown.txt")) == "done"
  end

  test "TODO tool updates explicit state through a graph command" do
    todo = Todo.new()

    node = ToolNode.new([todo])

    messages = [
      Message.assistant("",
        tool_calls: [
          %{
            id: "call-todo",
            name: "write_todos",
            args: %{"todos" => [%{"content" => "ship", "status" => "in_progress"}]}
          }
        ]
      )
    ]

    command = ToolNode.invoke(node, %{messages: messages, todos: []})

    assert [%{content: "ship", status: "in_progress"}] = command.update.todos
    assert [%Message{role: :tool, tool_call_id: "call-todo"} = message] = command.update.messages
    assert message.content =~ "Updated todo list to "
    refute message.content =~ ~s("todos")
  end

  test "TODO tool validates structured todo input and preserves state through commands" do
    todo = Todo.new()

    assert {:error, %{type: :invalid_input}} =
             Tool.invoke(todo, %{"action" => "add", "text" => "draft plan"})

    assert {:error, %{type: :invalid_input}} =
             Tool.invoke(todo, %{"todos" => [%{"text" => "draft plan", "status" => "pending"}]})

    assert {:error, %{type: :invalid_input}} =
             Tool.invoke(todo, %{"todos" => [%{"content" => "draft plan", "status" => "open"}]})

    assert {:error, %{type: :invalid_todo}} =
             Tool.invoke(todo, %{"todos" => [%{"content" => " ", "status" => "pending"}]})

    assert {:ok, %BeamWeaver.Graph.Command{update: update}} =
             Tool.invoke(todo, %{
               "todos" => [%{"content" => "draft plan", "status" => "in_progress"}],
               :state => %{todos: []},
               :tool_call_id => "call-add"
             })

    assert [%{content: "draft plan", status: "in_progress"}] = update.todos

    assert {:ok, %BeamWeaver.Graph.Command{update: update}} =
             Tool.invoke(todo, %{
               "todos" => [%{"content" => "ship plan", "status" => "in_progress"}],
               :state => %{todos: update.todos},
               :tool_call_id => "call-update"
             })

    assert [%{content: "ship plan", status: "in_progress"}] = update.todos

    assert {:ok, %BeamWeaver.Graph.Command{update: update}} =
             Tool.invoke(todo, %{
               "todos" => [%{"content" => "ship plan", "status" => "completed"}],
               :state => %{todos: update.todos},
               :tool_call_id => "call-complete"
             })

    assert [%{content: "ship plan", status: "completed"}] = update.todos

    assert {:error, %{type: :invalid_input}} =
             Tool.invoke(todo, %{"todos" => [%{"content" => "nope", "status" => "blocked"}]})

    assert {:error, %{type: :invalid_input}} =
             Tool.invoke(todo, %{"todos" => "not an array"})
  end

  test "file search delegates to a vectorstore-backed retriever" do
    store = ETSVectorStore.new(embedding: %FakeEmbeddingModel{})
    docs = [Document.new!("alpha policy", metadata: %{path: "a.md"})]

    assert {:ok, [_id]} = VectorStore.add_documents(store, docs)

    tool = FileSearch.new(retriever: VectorStore.as_retriever(store, k: 1))

    assert {:ok, [result]} = Tool.invoke(tool, %{"query" => "alpha"})
    assert result.metadata == %{path: "a.md"}
  end

  test "filesystem file search applies path policy include exclude hidden and snippets" do
    root =
      Path.join(
        System.tmp_dir!(),
        "beam_weaver_file_search_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "docs"))
    File.mkdir_p!(Path.join(root, ".hidden"))
    on_exit(fn -> File.rm_rf(root) end)

    File.write!(
      Path.join(root, "docs/a.md"),
      "alpha before target phrase after " <> String.duplicate("tail ", 30)
    )

    File.write!(Path.join(root, "docs/b.txt"), "target phrase in excluded extension")
    File.write!(Path.join(root, ".hidden/secret.md"), "target phrase hidden")

    tool =
      FileSearch.new(
        roots: [root],
        include: ["**/*.md"],
        exclude: ["**/secret.md"],
        max_results: 5,
        snippet_bytes: 32
      )

    assert {:ok, [result]} = Tool.invoke(tool, %{"query" => "target phrase"})
    assert result.content =~ "target phrase"
    assert byte_size(result.content) <= 32
    assert result.metadata.relative_path == "docs/a.md"
    assert result.metadata.source == "filesystem"
  end

  test "filesystem file search supports hidden files and per-call result limits" do
    root =
      Path.join(
        System.tmp_dir!(),
        "beam_weaver_hidden_search_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, ".notes"))
    on_exit(fn -> File.rm_rf(root) end)

    File.write!(Path.join(root, "a.md"), "needle one")
    File.write!(Path.join(root, "b.md"), "needle two")
    File.write!(Path.join(root, ".notes/c.md"), "needle hidden")

    hidden_off = FileSearch.new(roots: [root], include: ["**/*.md"], max_results: 10)
    assert {:ok, results} = Tool.invoke(hidden_off, %{"query" => "needle"})
    assert Enum.map(results, & &1.metadata.relative_path) == ["a.md", "b.md"]

    hidden_on =
      FileSearch.new(roots: [root], include: ["**/*.md"], include_hidden?: true, max_results: 10)

    assert {:ok, [one]} = Tool.invoke(hidden_on, %{"query" => "needle", "max_results" => 1})
    assert one.metadata.relative_path == ".notes/c.md"
  end

  test "filesystem file search returns tagged errors for invalid policy and input" do
    root =
      Path.join(
        System.tmp_dir!(),
        "beam_weaver_invalid_search_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    tool = FileSearch.new(roots: [root], include: ["../*.md"])

    assert {:error, %{type: :invalid_file_search_pattern}} =
             Tool.invoke(tool, %{"query" => "needle"})

    valid = FileSearch.new(roots: [root])

    assert {:error, %{type: :invalid_file_search_query}} =
             Tool.invoke(valid, %{"query" => " "})

    assert {:error, %{type: :invalid_file_search_limit}} =
             Tool.invoke(valid, %{"query" => "needle", "max_results" => 0})

    missing = FileSearch.new(roots: [Path.join(root, "missing")])

    assert {:error, %{type: :file_search_root_not_found}} =
             Tool.invoke(missing, %{"query" => "needle"})
  end

  test "filesystem file search is literal case-insensitive and does not follow symlinks" do
    root =
      Path.join(
        System.tmp_dir!(),
        "beam_weaver_literal_search_#{System.unique_integer([:positive])}"
      )

    outside =
      Path.join(
        System.tmp_dir!(),
        "beam_weaver_literal_outside_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf(root) end)
    on_exit(fn -> File.rm_rf(outside) end)

    File.write!(Path.join(root, "notes.md"), "Needle .* [literal] content")
    File.write!(Path.join(outside, "secret.md"), "Needle outside")
    File.ln_s!(outside, Path.join(root, "linked"))

    tool = FileSearch.new(roots: [root], include: ["**/*.md"], include_hidden?: true)

    assert {:ok, [result]} = Tool.invoke(tool, %{"query" => "needle .* [literal]"})
    assert result.metadata.relative_path == "notes.md"

    assert {:ok, []} = Tool.invoke(tool, %{"query" => "outside"})

    tilde = FileSearch.new(roots: [root], include: ["~/*.md"])

    assert {:error, %{type: :invalid_file_search_pattern}} =
             Tool.invoke(tilde, %{"query" => "needle"})
  end

  test "filesystem file search expands brace include patterns" do
    root =
      Path.join(
        System.tmp_dir!(),
        "beam_weaver_brace_search_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    File.write!(Path.join(root, "test.py"), "needle")
    File.write!(Path.join(root, "test.txt"), "needle")
    File.write!(Path.join(root, "test.md"), "needle")

    tool = FileSearch.new(roots: [root], include: ["*.{py,txt}"], max_results: 10)

    assert {:ok, results} = Tool.invoke(tool, %{"query" => "needle"})
    assert Enum.map(results, & &1.metadata.relative_path) == ["test.py", "test.txt"]

    nested = FileSearch.new(roots: [root], include: ["test.{p,t}{y,xt}"], max_results: 10)
    assert {:ok, nested_results} = Tool.invoke(nested, %{"query" => "needle"})
    assert Enum.map(nested_results, & &1.metadata.relative_path) == ["test.py", "test.txt"]

    invalid = FileSearch.new(roots: [root], include: ["*.{}"])

    assert {:error, %{type: :invalid_file_search_pattern}} =
             Tool.invoke(invalid, %{"query" => "needle"})
  end

  test "filesystem file search can order results by mtime descending" do
    root =
      Path.join(
        System.tmp_dir!(),
        "beam_weaver_mtime_search_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    oldest = Path.join(root, "a_oldest.txt")
    middle = Path.join(root, "b_middle.txt")
    newest = Path.join(root, "c_newest.txt")

    Enum.each([oldest, middle, newest], &File.write!(&1, "needle"))
    File.touch!(oldest, {{2001, 9, 9}, {1, 46, 40}})
    File.touch!(middle, {{2033, 5, 18}, {3, 33, 20}})
    File.touch!(newest, {{2065, 1, 24}, {5, 20, 0}})

    tool = FileSearch.new(roots: [root], include: ["*.txt"], sort: :mtime_desc, max_results: 10)

    assert {:ok, results} = Tool.invoke(tool, %{"query" => "needle"})

    assert Enum.map(results, & &1.metadata.relative_path) == [
             "c_newest.txt",
             "b_middle.txt",
             "a_oldest.txt"
           ]
  end

  test "filesystem file search supports regex count mode and invalid regex errors" do
    root =
      Path.join(
        System.tmp_dir!(),
        "beam_weaver_regex_search_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    File.write!(Path.join(root, "test.py"), "hello\nhello\nworld\n")

    tool = FileSearch.new(roots: [root], include: ["*.py"], query_mode: :regex)

    assert {:ok, [result]} =
             Tool.invoke(tool, %{
               "query" => "h.llo",
               "output_mode" => "count"
             })

    assert result.content == "2"
    assert result.metadata.match_count == 2

    assert {:error, %{type: :invalid_file_search_regex}} =
             Tool.invoke(tool, %{"query" => "[invalid"})
  end

  test "filesystem file search skips files larger than the configured limit" do
    root =
      Path.join(
        System.tmp_dir!(),
        "beam_weaver_large_search_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    File.write!(Path.join(root, "large.txt"), String.duplicate("x", 2 * 1024 * 1024))
    File.write!(Path.join(root, "small.txt"), "x")

    tool =
      FileSearch.new(
        roots: [root],
        include: ["*.txt"],
        max_file_bytes: 1024 * 1024,
        max_results: 10
      )

    assert {:ok, results} = Tool.invoke(tool, %{"query" => "x"})
    assert Enum.map(results, & &1.metadata.relative_path) == ["small.txt"]
  end
end
