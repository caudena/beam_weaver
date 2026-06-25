defmodule BeamWeaver.AgentCapabilitiesTest.AsyncClientFake do
  @behaviour BeamWeaver.Agent.Protocol.Client

  def start_task(subagent, payload, _opts) do
    {:ok,
     %{
       "id" => "remote-run",
       "status" => "running",
       "assistant_id" => subagent.graph_id,
       "input" => payload.input
     }}
  end

  def check_task(_subagent, "remote-run", _opts),
    do: {:ok, %{"id" => "remote-run", "status" => "complete", "result" => "done"}}

  def update_task(_subagent, task_id, message, _opts),
    do: {:ok, %{"id" => task_id, "status" => "running", "last_update" => message}}

  def cancel_task(_subagent, task_id, _opts),
    do: {:ok, %{"id" => task_id, "status" => "cancelled"}}
end

defmodule BeamWeaver.AgentCapabilitiesTest.AsyncClientThreadFake do
  @behaviour BeamWeaver.Agent.Protocol.Client

  def start_task(_subagent, _payload, _opts),
    do: {:ok, %{"thread_id" => "thread-1", "run_id" => "run-1", "status" => "running"}}

  def check_task(_subagent, "thread-1", _opts),
    do:
      {:ok,
       %{
         "thread_id" => "thread-1",
         "run_id" => "run-1",
         "status" => "success",
         "values" => %{"messages" => [%{"role" => "assistant", "content" => "final output"}]}
       }}

  def update_task(_subagent, task_id, message, _opts),
    do: {:ok, %{"thread_id" => task_id, "run_id" => "run-2", "status" => "running", "result" => message}}

  def cancel_task(_subagent, task_id, _opts),
    do: {:ok, %{"thread_id" => task_id, "status" => "cancelled"}}
end

defmodule BeamWeaver.AgentCapabilitiesTest.OverflowOnceModel do
  @behaviour BeamWeaver.Core.ChatModel

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message

  defstruct [:table, :parent]

  @impl true
  def invoke(%__MODULE__{table: table, parent: parent}, messages, _opts) do
    count = :ets.update_counter(table, :calls, {2, 1}, {:calls, 0})
    send(parent, {:overflow_once_model_call, count, messages})

    if count == 1 do
      {:error, Error.new(:context_overflow, "maximum context length exceeded")}
    else
      {:ok, Message.assistant("recovered")}
    end
  end
end

defmodule BeamWeaver.AgentCapabilitiesTest.ResearchThenGenerateModel do
  @behaviour BeamWeaver.Core.ChatModel

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool

  defstruct [:parent, supports_structured_output: true]

  @impl true
  def invoke(%__MODULE__{parent: parent}, messages, opts) do
    if parent do
      send(parent, {
        :research_then_generate_call,
        Enum.map(messages, & &1.role),
        opts |> Keyword.get(:tools, []) |> Enum.map(&Tool.name/1),
        Keyword.has_key?(opts, :response_format)
      })
    end

    cond do
      Keyword.has_key?(opts, :response_format) ->
        {:ok, Message.assistant("", metadata: %{parsed: %{"answer" => "generated", "facts" => []}})}

      Enum.any?(messages, &match?(%Message{role: :tool, name: "lookup"}, &1)) ->
        {:ok, Message.assistant([%{type: :text, text: "research notes"}])}

      true ->
        {:ok,
         Message.assistant("",
           tool_calls: [
             %{id: "call-lookup", name: "lookup", args: %{"query" => "deal"}}
           ]
         )}
    end
  end
end

defmodule BeamWeaver.AgentCapabilitiesTest.InputEchoStructuredModel do
  @behaviour BeamWeaver.Core.ChatModel

  alias BeamWeaver.Core.Message

  defstruct [:parent, supports_structured_output: true]

  @impl true
  def invoke(%__MODULE__{parent: parent}, messages, _opts) do
    description =
      messages
      |> List.last()
      |> Message.text()

    answer =
      cond do
        String.contains?(description, "first") -> "first"
        String.contains?(description, "second") -> "second"
        true -> "unknown"
      end

    if parent, do: send(parent, {:input_echo_structured_call, answer})

    {:ok, Message.assistant("", metadata: %{parsed: %{"answer" => answer, "facts" => []}})}
  end
end

defmodule BeamWeaver.AgentCapabilitiesTest.ChildStateRecorderMiddleware do
  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.ModelRequest

  defstruct [:parent]

  def new(opts \\ []), do: %__MODULE__{parent: Keyword.get(opts, :parent)}

  @impl true
  def name(_middleware), do: :child_state_recorder

  def wrap_model_call(%__MODULE__{parent: parent}, %ModelRequest{state: state} = request, handler) do
    if parent, do: send(parent, {:child_subagent_state, state})
    handler.(request)
  end
end

defmodule BeamWeaver.AgentCapabilitiesTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent
  alias BeamWeaver.Agent.Built
  alias BeamWeaver.Agent.CapabilityProfile
  alias BeamWeaver.Agent.CapabilityProfileConfig
  alias BeamWeaver.Agent.ExtendedModelResponse
  alias BeamWeaver.Agent.GeneralPurposeSubagentProfile
  alias BeamWeaver.Agent.Middleware
  alias BeamWeaver.Agent.Middleware.OverflowRecovery
  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Agent.ModelResolver, as: DeepAgentModels
  alias BeamWeaver.Agent.ModelResponse
  alias BeamWeaver.Agent.ProviderProfile
  alias BeamWeaver.Agent.Subagent.AsyncSpec
  alias BeamWeaver.Agent.Subagent.Spec
  alias BeamWeaver.Agent.ToolCallRequest
  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.ToolCall
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Core.ToolRuntime
  alias BeamWeaver.Filesystem
  alias BeamWeaver.Filesystem.Composite
  alias BeamWeaver.Filesystem.Local
  alias BeamWeaver.Filesystem.LocalShell
  alias BeamWeaver.Filesystem.Permission
  alias BeamWeaver.Filesystem.State
  alias BeamWeaver.Filesystem.Store
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.ExecutionInfo
  alias BeamWeaver.Graph.MessagesReducer
  alias BeamWeaver.Graph.Nodes.ToolNode
  alias BeamWeaver.Graph.Overwrite
  alias BeamWeaver.Graph.Runtime
  alias BeamWeaver.Models.FakeChatModel
  alias BeamWeaver.Tools.Filesystem, as: FilesystemTools
  alias BeamWeaver.Tools.Helpers, as: DeepAgentTools
  alias BeamWeaver.Tools.Subagents, as: SubagentTools
  alias BeamWeaver.Tools.Todo, as: TodoTools

  test "capability options build a normal BeamWeaver agent" do
    assert {:ok, %Built{} = agent} =
             Agent.build(
               model: %FakeChatModel{response: "done"},
               filesystem: State.new(),
               subagents: []
             )

    assert agent.spec.recursion_limit == 9999

    assert {:ok, %{messages: messages}} =
             Agent.invoke(agent, %{messages: [Message.user("hello")]})

    assert [%Message{role: :user}, %Message{role: :assistant, content: "done"}] = messages
  end

  test "manually composed tools count as agent capabilities" do
    tool =
      Tool.from_function!(
        name: "lookup",
        description: "Look up a value.",
        input_schema: %{
          "type" => "object",
          "properties" => %{"query" => %{"type" => "string"}},
          "required" => ["query"]
        },
        handler: fn _input, _opts -> {:ok, "found"} end
      )

    assert {:ok, %Built{} = agent} =
             Agent.build(
               model: %FakeChatModel{response: "done"},
               tools: [tool]
             )

    assert agent.spec.recursion_limit == 9999
    assert Enum.any?(agent.spec.middleware, &match?(%Middleware.ToolCallNormalization{}, &1))
  end

  test "manually composed middleware counts as agent capability" do
    assert {:ok, %Built{} = agent} =
             Agent.build(
               model: %FakeChatModel{response: "done"},
               middleware: [Middleware.TodoList.new()]
             )

    assert agent.spec.recursion_limit == 9999
    assert Enum.any?(agent.spec.middleware, &match?(%Middleware.ToolCallNormalization{}, &1))
  end

  test "bare middleware modules are loaded before callback discovery" do
    assert {:ok, %Built{} = agent} =
             Agent.build(
               model: %FakeChatModel{response: "done"},
               middleware: [Middleware.SubagentOutputs]
             )

    channels = agent.compiled.graph.channels

    assert Map.has_key?(channels, :subagent_outputs)
    assert Map.has_key?(channels, :subagent_cache)
  end

  test "bare middleware modules with default constructors are normalized to structs" do
    assert {:ok, %Middleware.ToolCallNormalization{}} =
             Middleware.normalize(Middleware.ToolCallNormalization)

    assert {:ok, %Built{} = agent} =
             Agent.build(
               model: %FakeChatModel{response: "done"},
               middleware: [Middleware.ToolCallNormalization]
             )

    assert {:ok, _result} = Agent.invoke(agent, %{messages: [%{role: "user", content: "hello"}]})
  end

  test "project version exposes the BeamWeaver package version" do
    assert is_binary(Mix.Project.config()[:version])
  end

  test "graph defaults expose base prompt and mandatory-model decision" do
    assert BeamWeaver.Agent.Defaults.base_agent_prompt() =~ "You are a DeepAgent"

    assert {:error, error} = BeamWeaver.Agent.Defaults.get_default_model()
    assert error.message =~ "requires a :model option"
  end

  test "model helpers resolve string specs and inspect identifiers" do
    model = %FakeChatModel{response: "done"}

    assert {:ok, ^model} = DeepAgentModels.resolve_model(model)

    assert {:ok, %FakeChatModel{response: "from spec"} = resolved} =
             DeepAgentModels.resolve_model("fake:chat", response: "from spec")

    assert DeepAgentModels.get_model_identifier(%{model_name: "preferred", model: "fallback"}) ==
             "preferred"

    assert DeepAgentModels.get_model_identifier(%{model: "fallback"}) == "fallback"
    assert DeepAgentModels.get_model_identifier(resolved) == "chat"
    assert DeepAgentModels.get_model_provider(resolved) == "fake"
    assert DeepAgentModels.model_matches_spec(resolved, "fake:chat")
    refute DeepAgentModels.model_matches_spec(resolved, "openai:gpt-5")
  end

  test "tool helpers copy supported tools and apply description overrides" do
    tool =
      Tool.from_function!(
        name: "lookup",
        description: "old",
        input_schema: %{"type" => "object", "properties" => %{}},
        handler: fn _input, _opts -> "ok" end
      )

    map_tool = %{name: "search", description: "old map"}
    callable = fn -> :ok end

    assert DeepAgentTools.tool_name(tool) == "lookup"
    assert DeepAgentTools.tool_name(map_tool) == "search"
    assert DeepAgentTools.tool_name(callable) == nil

    rewritten =
      DeepAgentTools.apply_tool_description_overrides([tool, map_tool, callable], %{
        "lookup" => "new",
        search: "new map"
      })

    assert [%Tool{description: "new"}, %{description: "new map"}, ^callable] = rewritten
    assert tool.description == "old"
    assert map_tool.description == "old map"
  end

  test "built-in deep agent capabilities are composable toolkits" do
    todo_names = TodoTools.tools(name: "write_todos") |> Enum.map(&Tool.name/1)
    filesystem_names = FilesystemTools.tools(backend: State.new()) |> Enum.map(&Tool.name/1)

    subagent_names =
      SubagentTools.tools(
        model: %FakeChatModel{response: "ok"},
        subagents: [%Spec{name: "worker", description: "Worker", system_prompt: "You are a worker."}]
      )
      |> Enum.map(&Tool.name/1)

    assert todo_names == ["write_todos"]
    assert filesystem_names == ["ls", "read_file", "write_file", "edit_file", "glob", "grep"]
    assert subagent_names == ["task"]
  end

  test "create/1 resolves string model specs before building the agent" do
    assert {:ok, %Built{} = agent} =
             Agent.build(
               model: "fake:chat",
               model_opts: [response: "done"],
               summarization: false,
               subagents: []
             )

    assert %FakeChatModel{response: "done"} = agent.spec.model

    assert {:ok, %{messages: [_user, %Message{content: "done"}]}} =
             Agent.invoke(agent, %{messages: [Message.user("hello")]})
  end

  test "DeepAgents messages reducer assigns ids, deduplicates, and resets on remove-all" do
    existing = [Message.assistant("hello", id: "existing-1")]
    follow_up = Message.user("follow-up")

    assert [first, second] = MessagesReducer.delta_reducer(existing, [[follow_up]])
    assert first.id == "existing-1"
    assert second.content == "follow-up"
    assert is_binary(second.id)

    assert [^first, updated] =
             MessagesReducer.delta_reducer(
               [first, second],
               [Message.user("updated", id: second.id)]
             )

    assert updated.content == "updated"
    assert updated.id == second.id

    assert [%Message{role: :system, content: "new"}] =
             MessagesReducer.delta_reducer([first, second], [
               MessagesReducer.remove_all(),
               Message.system("new")
             ])
  end

  test "state backend writes, reads, edits, globs, and greps virtual files" do
    backend = State.new()

    assert %Filesystem.WriteResult{error: nil, files_update: files} =
             State.write(backend, "/notes/a.txt", "hello\nneedle", state: %{})

    state = %{files: files}

    assert %Filesystem.ReadResult{file_data: %Filesystem.FileData{content: "hello\nneedle"}} =
             State.read(backend, "/notes/a.txt", state: state)

    assert %Filesystem.ReadResult{file_data: %Filesystem.FileData{content: ""}} =
             State.read(backend, "/notes/a.txt", state: state, offset: 99, limit: 10)

    assert %Filesystem.EditResult{error: nil, files_update: edited} =
             State.edit(backend, "/notes/a.txt", "needle", "thread", state: state)

    state = %{files: edited}

    assert %Filesystem.GlobResult{matches: [%Filesystem.FileInfo{path: "/notes/a.txt"}]} =
             State.glob(backend, "**/*.txt", state: state)

    assert %Filesystem.GrepResult{matches: [%Filesystem.GrepMatch{text: "thread"}]} =
             State.grep(backend, "thread", state: state)
  end

  test "backend protocol exposes async functions and raw grep formatting" do
    backend = State.new()

    assert BeamWeaver.Filesystem.Backend.impl_for(backend)

    assert %Filesystem.WriteResult{files_update: files} =
             Filesystem.write(backend, "/notes/a.txt", "hello\nneedle", state: %{})

    state = %{files: files}

    assert %Filesystem.ReadResult{file_data: %Filesystem.FileData{content: "hello\nneedle"}} =
             backend
             |> Filesystem.async_read("/notes/a.txt", state: state)
             |> Task.await()

    assert %Filesystem.LsResult{entries: [%Filesystem.FileInfo{path: "/notes"}]} =
             Filesystem.ls_info(backend, "/", state: state)

    assert Filesystem.grep_raw(backend, "needle", state: state) == "/notes/a.txt:2:needle"
  end

  test "backend utility helpers expose DeepAgents-compatible formatting and data helpers" do
    assert BeamWeaver.Filesystem.Utils.empty_content_warning() =~ "empty contents"
    assert BeamWeaver.Filesystem.Utils.check_empty_content("  ") =~ "empty contents"
    assert BeamWeaver.Filesystem.Utils.sanitize_tool_call_id("a.b/c\\d") == "a_b_c_d"
    assert BeamWeaver.Filesystem.Utils.to_posix_path("a\\b") == "a/b"
    assert BeamWeaver.Filesystem.Utils.validate_path("notes/./a.txt") == "/notes/a.txt"

    assert_raise ArgumentError, ~r/Path traversal not allowed/, fn ->
      BeamWeaver.Filesystem.Utils.validate_path("../secret")
    end

    data = BeamWeaver.Filesystem.Utils.create_file_data("hello")
    assert %Filesystem.FileData{content: "hello", encoding: "utf-8"} = data

    updated = BeamWeaver.Filesystem.Utils.update_file_data(data, "updated")
    assert updated.content == "updated"
    assert updated.created_at == data.created_at
    assert updated.modified_at != nil

    assert BeamWeaver.Filesystem.Utils.slice_read_response(updated, 0, 1) == "updated"

    assert BeamWeaver.Filesystem.Utils.file_data_to_string(%{"content" => ["a", "b"]}) ==
             "a\nb"

    formatted =
      BeamWeaver.Filesystem.Utils.format_content_with_line_numbers("abcdef",
        max_line_length: 3
      )

    assert formatted == "     1\tabc\n   1.1\tdef"

    matches = [
      %Filesystem.GrepMatch{path: "/a.txt", line: 1, text: "needle"},
      %Filesystem.GrepMatch{path: "/a.txt", line: 2, text: "needle again"}
    ]

    assert BeamWeaver.Filesystem.Utils.format_grep_matches(matches, :count) ==
             "/a.txt: 2"

    assert %Filesystem.GrepResult{matches: [%Filesystem.GrepMatch{text: "hello"}]} =
             BeamWeaver.Filesystem.Utils.grep_matches_from_files(
               %{"/a.txt" => data},
               "hello"
             )

    assert BeamWeaver.Filesystem.Utils.truncate_if_too_long(["abcdef", "gh"], 4) == [
             "abcdef",
             BeamWeaver.Filesystem.Utils.truncation_guidance()
           ]
  end

  test "store backend persists uploads and supports runtime namespace factories" do
    store = BeamWeaver.Memory.ETS.new()

    backend =
      Store.new(
        store: store,
        namespace: fn runtime -> ["deepagents", runtime.context.user_id] end
      )

    runtime = %{context: %{user_id: "u1"}}

    assert [%Filesystem.UploadResult{path: "/notes/a.txt", error: nil}] =
             Filesystem.upload_files(backend, [{"/notes/a.txt", "hello store"}], runtime: runtime)

    assert %Filesystem.ReadResult{file_data: %Filesystem.FileData{content: "hello store"}} =
             Filesystem.read(backend, "/notes/a.txt", runtime: runtime)

    assert_raise ArgumentError, fn -> Store.new(namespace: ["bad*namespace"]) end
  end

  test "store backend upload and download round-trip binary file data" do
    store = BeamWeaver.Memory.ETS.new()
    backend = Store.new(store: store, namespace: ["deepagents", "binary"])
    png = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 1, 2, 3>>

    assert [%Filesystem.UploadResult{path: "/images/test.png", error: nil}] =
             Filesystem.upload_files(backend, [{"/images/test.png", png}])

    assert %Filesystem.ReadResult{
             file_data: %Filesystem.FileData{encoding: "base64", content: encoded}
           } = Filesystem.read(backend, "/images/test.png")

    assert Base.decode64!(encoded) == png

    assert [%Filesystem.DownloadResult{path: "/images/test.png", content: ^png, error: nil}] =
             Filesystem.download_files(backend, ["/images/test.png"])
  end

  test "filesystem tools return graph commands for state-backed writes" do
    [_, _, write_tool | _] = FilesystemTools.tools(State.new())

    assert {:ok, %Command{update: %{files: files, messages: [%Message{name: "write_file"}]}}} =
             Tool.invoke(write_tool, %{
               "file_path" => "/work/plan.md",
               "content" => "ship it",
               state: %{},
               tool_call_id: "call-write"
             })

    assert %Filesystem.FileData{content: "ship it"} = files["/work/plan.md"]
  end

  test "filesystem permissions deny matching operations before backend access" do
    permission =
      Permission.new(
        operations: [:write],
        paths: ["/locked/**"],
        mode: :deny
      )

    [_, _, write_tool | _] = FilesystemTools.tools(State.new(), permissions: [permission])

    assert {:ok, "Error: Permission denied writing /locked/secret.txt"} =
             Tool.invoke(write_tool, %{
               "file_path" => "/locked/secret.txt",
               "content" => "secret",
               state: %{},
               tool_call_id: "call-deny"
             })
  end

  test "filesystem permissions validate paths and first matching rule wins" do
    assert_raise ArgumentError, ~r/must start with/, fn ->
      Permission.new(operations: [:read], paths: ["relative/**"])
    end

    assert_raise ArgumentError, ~r/must not contain '\.\.'/i, fn ->
      Permission.new(operations: [:read], paths: ["/workspace\\..\\secret/**"])
    end

    permissions = [
      Permission.new(operations: [:read], paths: ["/data/{a,b}.txt"], mode: :deny),
      Permission.new(operations: [:read], paths: ["/data/**"], mode: :allow)
    ]

    refute Permission.allowed?(permissions, :read, "/data/a.txt")
    refute Permission.allowed?(permissions, :read, "/data/b.txt")
    assert Permission.allowed?(permissions, :read, "/data/c.txt")
  end

  test "filesystem read permissions post-filter listed and searched paths" do
    backend = State.new()

    files = %{
      "/public/a.txt" => %Filesystem.FileData{content: "needle public", encoding: "utf-8"},
      "/secrets/b.txt" => %Filesystem.FileData{content: "needle secret", encoding: "utf-8"}
    }

    permission =
      Permission.new(
        operations: [:read],
        paths: ["/secrets/**"],
        mode: :deny
      )

    tools = FilesystemTools.tools(backend, permissions: [permission])
    ls_tool = Enum.find(tools, &(Tool.name(&1) == "ls"))
    glob_tool = Enum.find(tools, &(Tool.name(&1) == "glob"))
    grep_tool = Enum.find(tools, &(Tool.name(&1) == "grep"))

    assert {:ok, listed} = Tool.invoke(ls_tool, %{"path" => "/", state: %{files: files}})
    assert listed =~ "/public"
    refute listed =~ "/secrets"

    assert {:ok, globbed} =
             Tool.invoke(glob_tool, %{
               "path" => "/",
               "pattern" => "**/*.txt",
               state: %{files: files}
             })

    assert globbed =~ "/public/a.txt"
    refute globbed =~ "/secrets/b.txt"

    assert {:ok, grepped} =
             Tool.invoke(grep_tool, %{"pattern" => "needle", state: %{files: files}})

    assert grepped =~ "/public/a.txt"
    refute grepped =~ "/secrets/b.txt"
  end

  test "filesystem middleware injects filesystem and execution instructions" do
    middleware = Middleware.Filesystem.new(backend: LocalShell.new(root: tmp_root()))
    request = ModelRequest.new(system_prompt: "base")

    assert %ModelRequest{system_message: %Message{content: prompt}} =
             Middleware.Filesystem.wrap_model_call(middleware, request, & &1)

    assert prompt =~ "base"
    assert prompt =~ "Filesystem Tools"
    assert prompt =~ "/large_tool_results/<tool_call_id>"
    assert prompt =~ "Execute Tool"
  end

  test "filesystem middleware offloads oversized tool results into state backend" do
    middleware = Middleware.Filesystem.new(tool_token_limit_before_evict: 2)

    request = %ToolCallRequest{
      tool_call: %{id: "call.big/result", name: "expensive_tool", args: %{}},
      state: %{},
      runtime: %{}
    }

    large_result = Enum.map_join(1..12, "\n", &"line #{&1}")

    assert %Command{update: %{files: files, messages: [%Message{} = message]}} =
             Middleware.Filesystem.wrap_tool_call(middleware, request, fn _request ->
               Message.tool(large_result, tool_call_id: "call.big/result", name: "expensive_tool")
             end)

    assert files["/large_tool_results/call_big_result"].content == large_result
    assert message.content =~ "Tool result too large"
    assert message.content =~ "/large_tool_results/call_big_result"
    assert message.content =~ "... [2 lines truncated] ..."
  end

  test "filesystem middleware offloads command tool messages and preserves command updates" do
    middleware = Middleware.Filesystem.new(tool_token_limit_before_evict: 1)

    request = %ToolCallRequest{
      tool_call: %{id: "call-big", name: "expensive_tool", args: %{}},
      state: %{},
      runtime: %{}
    }

    result =
      Middleware.Filesystem.wrap_tool_call(middleware, request, fn _request ->
        %Command{
          update: %{
            custom: :kept,
            messages: [
              Message.tool("ok", tool_call_id: "small", name: "other"),
              Message.tool(String.duplicate("x", 20),
                tool_call_id: "call-big",
                name: "expensive_tool"
              )
            ]
          }
        }
      end)

    assert %Command{update: %{custom: :kept, files: files, messages: messages}} = result
    assert files["/large_tool_results/call-big"].content == String.duplicate("x", 20)
    assert [%Message{content: "ok"}, %Message{content: offloaded}] = messages
    assert offloaded =~ "Tool result too large"
  end

  test "filesystem middleware does not evict filesystem tool results" do
    middleware = Middleware.Filesystem.new(tool_token_limit_before_evict: 1)

    request = %ToolCallRequest{
      tool_call: %{id: "call-read", name: "read_file", args: %{}},
      state: %{},
      runtime: %{}
    }

    content = String.duplicate("x", 100)

    assert %Message{content: ^content} =
             Middleware.Filesystem.wrap_tool_call(middleware, request, fn _request ->
               Message.tool(content, tool_call_id: "call-read", name: "read_file")
             end)
  end

  test "filesystem middleware offloads oversized user messages before model calls" do
    parent = self()
    middleware = Middleware.Filesystem.new(human_message_token_limit_before_evict: 2)
    large_message = Enum.map_join(1..12, "\n", &"line #{&1}")

    request =
      ModelRequest.new(
        messages: [Message.user(large_message)],
        state: %{},
        runtime: %{}
      )

    assert %ExtendedModelResponse{
             model_response: %ModelResponse{messages: [%Message{content: "ok"}]},
             command: %Command{update: %{files: files, messages: %Overwrite{} = overwrite}}
           } =
             Middleware.Filesystem.wrap_model_call(middleware, request, fn model_request ->
               send(parent, {:model_messages, model_request.messages})
               %ModelResponse{messages: [Message.assistant("ok")]}
             end)

    assert_receive {:model_messages, [%Message{content: preview}]}
    assert preview =~ "Message content too large"
    assert preview =~ "/conversation_history/"
    assert preview =~ "... [2 lines truncated] ..."

    assert {:ok, [%Message{content: ^large_message, metadata: metadata, id: id}]} =
             Overwrite.get(overwrite)

    assert is_binary(id)
    path = Map.fetch!(metadata, :offloaded_to)
    assert String.starts_with?(path, "/conversation_history/")
    assert files[path].content == large_message
  end

  test "filesystem middleware truncates previously offloaded user messages without writing again" do
    parent = self()
    middleware = Middleware.Filesystem.new(human_message_token_limit_before_evict: 2)

    request =
      ModelRequest.new(
        messages: [
          Message.user("very large remembered content",
            metadata: %{offloaded_to: "/conversation_history/original.md"}
          )
        ],
        state: %{},
        runtime: %{}
      )

    assert %ModelResponse{messages: [%Message{content: "ok"}]} =
             Middleware.Filesystem.wrap_model_call(middleware, request, fn model_request ->
               send(parent, {:model_messages, model_request.messages})
               %ModelResponse{messages: [Message.assistant("ok")]}
             end)

    assert_receive {:model_messages, [%Message{content: preview}]}
    assert preview =~ "Message content too large"
    assert preview =~ "/conversation_history/original.md"
  end

  test "compact conversation tool summarizes old messages and records a deferred overwrite event" do
    middleware =
      Middleware.CompactConversation.new(
        model: %FakeChatModel{response: "short summary"},
        backend: State.new(),
        minimum_messages: 4,
        keep_messages: 2
      )

    [tool] = Middleware.CompactConversation.tools(middleware)

    messages = [
      Message.user("one"),
      Message.assistant("two"),
      Message.user("three"),
      Message.assistant("four"),
      Message.user("five")
    ]

    assert {:ok, %Command{update: update}} =
             Tool.invoke(tool, %{
               state: %{messages: messages},
               tool_call_id: "compact-1"
             })

    assert %{_summarization_event: event, files: files, messages: [tool_message]} = update
    assert %Message{role: :tool, name: "compact_conversation"} = tool_message
    assert tool_message.content =~ "Conversation compacted"

    assert %Message{role: :user, content: summary} = event.summary_message
    assert summary =~ "short summary"
    assert String.starts_with?(event.file_path, "/conversation_history/")
    assert files[event.file_path].content =~ "Human: one"

    state = %{
      messages: messages ++ [tool_message],
      _summarization_event: event
    }

    assert %{messages: %Overwrite{} = overwrite} =
             Middleware.CompactConversation.before_model(middleware, state, %{})

    assert {:ok, compacted} = Overwrite.get(overwrite)
    assert [%Message{role: :user, content: ^summary} | recent] = compacted
    assert Enum.map(recent, & &1.content) == ["four", "five", tool_message.content]
  end

  test "compact conversation preserves assistant tool-call pairs at the retention boundary" do
    middleware =
      Middleware.CompactConversation.new(
        model: %FakeChatModel{response: "short summary"},
        backend: State.new(),
        minimum_messages: 4,
        keep_messages: 3
      )

    [tool] = Middleware.CompactConversation.tools(middleware)

    messages = [
      Message.user("one"),
      Message.assistant("checking",
        tool_calls: [%ToolCall{id: "call-1", name: "lookup", args: %{}}]
      ),
      Message.tool("result", tool_call_id: "call-1"),
      Message.user("four"),
      Message.assistant("five")
    ]

    assert {:ok, %Command{update: update}} =
             Tool.invoke(tool, %{
               state: %{messages: messages},
               tool_call_id: "compact-1"
             })

    state = %{
      messages: messages ++ update.messages,
      _summarization_event: update._summarization_event
    }

    assert %{messages: %Overwrite{} = overwrite} =
             Middleware.CompactConversation.before_model(middleware, state, %{})

    assert {:ok, [summary | recent]} = Overwrite.get(overwrite)
    assert %Message{role: :user, content: "Conversation summary:\nshort summary"} = summary

    assert [
             %Message{role: :assistant, tool_calls: [%ToolCall{id: "call-1"}]},
             %Message{role: :tool, tool_call_id: "call-1"},
             %Message{role: :user, content: "four"},
             %Message{role: :assistant, content: "five"},
             %Message{role: :tool, name: "compact_conversation"}
           ] = recent
  end

  test "compact conversation drops orphan tool messages at the retention boundary" do
    middleware =
      Middleware.CompactConversation.new(
        model: %FakeChatModel{response: "short summary"},
        backend: State.new(),
        minimum_messages: 4,
        keep_messages: 4
      )

    [tool] = Middleware.CompactConversation.tools(middleware)

    messages = [
      Message.user("one"),
      Message.tool("orphan one", tool_call_id: "missing-1", name: "lookup"),
      Message.tool("orphan two", tool_call_id: "missing-2", name: "lookup"),
      Message.user("after orphan"),
      Message.assistant("final")
    ]

    assert {:ok, %Command{update: update}} =
             Tool.invoke(tool, %{
               state: %{messages: messages},
               tool_call_id: "compact-orphan"
             })

    state = %{
      messages: messages ++ update.messages,
      _summarization_event: update._summarization_event
    }

    assert %{messages: %Overwrite{} = overwrite} =
             Middleware.CompactConversation.before_model(middleware, state, %{})

    assert {:ok, [_summary | recent]} = Overwrite.get(overwrite)

    refute Enum.any?(recent, fn
             %Message{role: :tool, tool_call_id: "missing-" <> _rest} -> true
             _message -> false
           end)

    assert [
             %Message{role: :user, content: "after orphan"},
             %Message{role: :assistant, content: "final"},
             %Message{role: :tool, name: "compact_conversation"}
           ] = recent
  end

  test "compact conversation tool is a no-op before the message threshold" do
    middleware =
      Middleware.CompactConversation.new(
        model: %FakeChatModel{response: "unused"},
        minimum_messages: 99
      )

    [tool] = Middleware.CompactConversation.tools(middleware)

    assert {:ok, %Command{update: update}} =
             Tool.invoke(tool, %{
               state: %{messages: [Message.user("short")]},
               tool_call_id: "compact-2"
             })

    refute Map.has_key?(update, :_summarization_event)
    assert %{messages: [%Message{role: :tool, content: content}]} = update
    assert content =~ "Nothing to compact"
  end

  test "compact conversation middleware injects the compact tool prompt" do
    middleware = Middleware.CompactConversation.new(model: %FakeChatModel{response: "ok"})
    request = ModelRequest.new(system_prompt: "base")

    assert %ModelRequest{system_message: %Message{content: prompt}} =
             Middleware.CompactConversation.wrap_model_call(middleware, request, & &1)

    assert prompt =~ "base"
    assert prompt =~ "compact_conversation"
  end

  test "prompt caching middleware marks Anthropic system prompt only" do
    middleware = Middleware.PromptCaching.new()

    anthropic_request =
      ModelRequest.new(
        model: BeamWeaver.Anthropic.ChatModel.new(),
        system_prompt: "base"
      )

    assert %ModelRequest{system_message: %Message{content: [block]}} =
             Middleware.PromptCaching.wrap_model_call(middleware, anthropic_request, & &1)

    assert block.text == "base"
    assert block.cache_control == %{"type" => "ephemeral"}

    fake_request = ModelRequest.new(model: %FakeChatModel{}, system_prompt: "base")

    assert %ModelRequest{system_message: %Message{content: "base"}} =
             Middleware.PromptCaching.wrap_model_call(middleware, fake_request, & &1)
  end

  test "overflow clip slices read_file tail messages and offloads generic tool tail messages" do
    backend = State.new()

    messages = [
      Message.assistant("tool calls",
        tool_calls: [
          %ToolCall{id: "read-1", name: "read_file", args: %{"file_path" => "/docs/big.md"}},
          %ToolCall{id: "run/1", name: "expensive_tool", args: %{}}
        ]
      ),
      Message.tool(String.duplicate("a", 4_500), tool_call_id: "read-1", name: "read_file"),
      Message.tool(Enum.map_join(1..12, "\n", &"line #{&1}"),
        tool_call_id: "run/1",
        name: "expensive_tool"
      )
    ]

    assert %OverflowRecovery{
             clipped?: true,
             messages: clipped,
             replacements: replacements,
             files_update: files
           } =
             OverflowRecovery.clip_tail(messages, backend, keep: {:tokens, 1}, state: %{})

    assert length(clipped) == 3
    assert length(replacements) == 2

    assert [%Message{content: read_preview}, %Message{content: offload_preview}] =
             Enum.take(clipped, -2)

    assert String.length(read_preview) < 4_500
    assert read_preview =~ "The full content is at /docs/big.md"
    assert offload_preview =~ "/large_tool_results/run_1"
    assert offload_preview =~ "... [2 lines truncated] ..."
    assert files["/large_tool_results/run_1"].content =~ "line 12"
    assert Enum.all?(replacements, &is_binary(&1.id))
  end

  test "overflow keep config is atom-only" do
    assert_raise ArgumentError, ~s(keep kind must be an atom, got "tokens"; use :tokens), fn ->
      OverflowRecovery.derive_threshold_tokens({"tokens", 1}, 10_000)
    end
  end

  test "overflow clip middleware retries context overflow with clipped tool tail" do
    table = :ets.new(:overflow_once_model, [:set, :public])

    assert {:ok, agent} =
             Agent.build(
               model: %BeamWeaver.AgentCapabilitiesTest.OverflowOnceModel{
                 table: table,
                 parent: self()
               },
               backend: State.new(),
               overflow_clip: [keep: {:tokens, 1}],
               subagents: [],
               summarization: true
             )

    messages = [
      Message.user("inspect the tool result"),
      Message.assistant("tool call",
        tool_calls: [%ToolCall{id: "big", name: "expensive_tool", args: %{}}]
      ),
      Message.tool(Enum.map_join(1..200, "\n", &"line #{&1}"),
        tool_call_id: "big",
        name: "expensive_tool"
      )
    ]

    assert {:ok, %{messages: result_messages}} = Agent.invoke(agent, %{messages: messages})
    assert List.last(result_messages).content == "recovered"

    assert_receive {:overflow_once_model_call, 1, first_messages}
    assert_receive {:overflow_once_model_call, 2, retried_messages}

    first_tool = List.last(first_messages)
    retried_tool = List.last(retried_messages)

    assert first_tool.content =~ "line 200"
    assert retried_tool.content =~ "/large_tool_results/big"
    assert String.length(retried_tool.content) < String.length(first_tool.content)
  end

  test "composite backend preserves routed virtual path prefixes in results" do
    files = %{
      "/note.txt" => %Filesystem.FileData{content: "hello\nneedle", encoding: "utf-8"}
    }

    backend =
      Composite.new(
        default: State.new(),
        routes: %{"/workspace/" => State.new()}
      )

    assert %Filesystem.LsResult{entries: [%Filesystem.FileInfo{path: "/workspace/note.txt"}]} =
             Composite.ls(backend, "/workspace", state: %{files: files})

    assert %Filesystem.GlobResult{matches: [%Filesystem.FileInfo{path: "/workspace/note.txt"}]} =
             Composite.glob(backend, "*.txt", path: "/workspace", state: %{files: files})

    assert %Filesystem.GrepResult{
             matches: [%Filesystem.GrepMatch{path: "/workspace/note.txt", text: "needle"}]
           } = Composite.grep(backend, "needle", path: "/workspace", state: %{files: files})
  end

  test "composite backend exposes execute through the default executable backend" do
    root = tmp_root()

    backend =
      Composite.new(
        default: LocalShell.new(root: root, env: %{"DEEPAGENTS_TEST" => "ok"}),
        routes: %{"/workspace/" => State.new()}
      )

    assert BeamWeaver.Filesystem.Executable.executable?(backend)
    assert BeamWeaver.Filesystem.ExecutableBackend.impl_for(backend)

    assert %BeamWeaver.Filesystem.Executable.ExecuteResult{
             exit_code: 0,
             output: "ok\n",
             truncated: false
           } =
             BeamWeaver.Filesystem.Executable.execute(
               backend,
               "printf \"$DEEPAGENTS_TEST\\n\""
             )
  end

  test "composite backend without an executable default does not expose execute tools" do
    backend =
      Composite.new(
        default: State.new(),
        routes: %{"/memory/" => State.new()}
      )

    refute BeamWeaver.Filesystem.Executable.executable?(backend)

    tool_names =
      backend
      |> FilesystemTools.tools()
      |> Enum.map(&Tool.name/1)

    refute "execute" in tool_names
  end

  test "filesystem backend blocks symlink escapes and lists missing directories as empty" do
    root = tmp_root()
    outside = tmp_root()
    File.write!(Path.join(outside, "secret.txt"), "secret")
    backend = Local.new(root: root)

    assert %Filesystem.LsResult{entries: []} = Filesystem.ls(backend, "/missing")

    case File.ln_s(Path.join(outside, "secret.txt"), Path.join(root, "secret-link.txt")) do
      :ok ->
        assert %Filesystem.ReadResult{error: "invalid_path"} =
                 Filesystem.read(backend, "/secret-link.txt")

      {:error, _reason} ->
        :ok
    end

    case File.ln_s(outside, Path.join(root, "escape-dir")) do
      :ok ->
        assert %Filesystem.WriteResult{error: "invalid_path"} =
                 Filesystem.write(backend, "/escape-dir/new.txt", "nope")

      {:error, _reason} ->
        :ok
    end
  end

  test "filesystem backend accepts root_dir constructor option" do
    root = tmp_root()
    backend = Local.new(root_dir: root)

    assert %Filesystem.WriteResult{path: "/note.txt", error: nil} =
             Filesystem.write(backend, "/note.txt", "root-dir")

    assert File.read!(Path.join(root, "note.txt")) == "root-dir"
  end

  test "local shell backend is filesystem compatible and runs unsafe host commands" do
    root = tmp_root()
    backend = LocalShell.new(root: root, env: %{"LOCAL_SHELL_MARKER" => "present"})

    assert %Filesystem.WriteResult{path: "/work/a.txt", error: nil} =
             Filesystem.write(backend, "/work/a.txt", "hello")

    assert %Filesystem.ReadResult{file_data: %Filesystem.FileData{content: "hello"}} =
             Filesystem.read(backend, "/work/a.txt")

    assert %BeamWeaver.Filesystem.Executable.ExecuteResult{
             exit_code: 0,
             output: "hello:present",
             truncated: false
           } =
             BeamWeaver.Filesystem.Executable.execute(
               backend,
               "printf \"$(cat work/a.txt):$LOCAL_SHELL_MARKER\""
             )

    System.put_env("DEEPAGENTS_INHERIT_TEST", "host")
    on_exit(fn -> System.delete_env("DEEPAGENTS_INHERIT_TEST") end)

    isolated = LocalShell.new(root: root, inherit_env: false, env: %{"LOCAL_ONLY" => "ok"})

    assert %BeamWeaver.Filesystem.Executable.ExecuteResult{
             exit_code: 0,
             output: ":ok"
           } =
             BeamWeaver.Filesystem.Executable.execute(
               isolated,
               "printf \"$DEEPAGENTS_INHERIT_TEST:$LOCAL_ONLY\""
             )
  end

  test "sandbox backend maps absolute virtual paths under the local sandbox root" do
    root = tmp_root()

    backend =
      BeamWeaver.Filesystem.Sandbox.new(sandbox: BeamWeaver.Sandbox.local(root: root))

    assert BeamWeaver.Filesystem.Sandbox.max_binary_bytes() == 500 * 1024
    assert BeamWeaver.Filesystem.Sandbox.max_output_bytes() == 500 * 1024
    assert BeamWeaver.Filesystem.Sandbox.truncation_msg() =~ "Output was truncated"

    assert %Filesystem.WriteResult{path: "/work/a.txt", error: nil} =
             Filesystem.write(backend, "/work/a.txt", "hello\nneedle")

    assert File.read!(Path.join(root, "work/a.txt")) == "hello\nneedle"

    assert %Filesystem.ReadResult{
             file_data: %Filesystem.FileData{content: "hello\nneedle", encoding: "utf-8"}
           } = Filesystem.read(backend, "/work/a.txt")

    assert %Filesystem.LsResult{
             entries: [%Filesystem.FileInfo{path: "/work/a.txt", is_dir: false}]
           } =
             Filesystem.ls(backend, "/work")

    assert %Filesystem.GlobResult{matches: [%Filesystem.FileInfo{path: "/work/a.txt"}]} =
             Filesystem.glob(backend, "*.txt", path: "/work")

    assert %Filesystem.GrepResult{matches: [%Filesystem.GrepMatch{path: "/work/a.txt"}]} =
             Filesystem.grep(backend, "needle", path: "/work")
  end

  test "execute tool validates timeout instead of silently clamping it" do
    backend =
      BeamWeaver.Filesystem.Sandbox.new(sandbox: BeamWeaver.Sandbox.local(root: tmp_root()))

    execute_tool =
      backend
      |> FilesystemTools.tools()
      |> Enum.find(&(Tool.name(&1) == "execute"))

    assert {:ok, "Error: timeout must be an integer between 1 and 3600 seconds"} =
             Tool.invoke(execute_tool, %{"command" => "echo no", "timeout" => 0})
  end

  test "sandbox backends validate direct execute timeout values" do
    assert %BeamWeaver.Filesystem.Executable.ExecuteResult{
             exit_code: nil,
             error: "timeout must be an integer between 1 and 3600 seconds"
           } =
             BeamWeaver.Filesystem.Executable.execute(
               LocalShell.new(root: tmp_root()),
               "echo no",
               timeout: 0
             )

    assert %BeamWeaver.Sandbox.ExecuteResult{
             exit_code: nil,
             error: "timeout must be an integer between 1 and 3600 seconds"
           } =
             BeamWeaver.Sandbox.execute(
               BeamWeaver.Sandbox.local(root: tmp_root()),
               "echo no",
               timeout: 0
             )
  end

  test "tool filtering excludes tools and overrides model-visible descriptions" do
    visible =
      Tool.from_function!(
        name: "visible",
        description: "Original description",
        input_schema: %{"type" => "object", "properties" => %{}},
        handler: fn _input, _opts -> "visible" end
      )

    hidden =
      Tool.from_function!(
        name: "hidden",
        description: "Hidden description",
        input_schema: %{"type" => "object", "properties" => %{}},
        handler: fn _input, _opts -> "hidden" end
      )

    assert {:ok, agent} =
             Agent.build(
               model: %FakeChatModel{response: "done", parent: self()},
               tools: [visible, hidden],
               exclude_tools: ["hidden"],
               tool_descriptions: %{"visible" => "Profile description"}
             )

    assert {:ok, _state} = Agent.invoke(agent, %{messages: [Message.user("hello")]})

    assert_receive {:fake_chat_model_call, _messages, opts}
    tools = Keyword.fetch!(opts, :tools)
    names = Enum.map(tools, &Tool.name/1)
    assert "visible" in names
    refute "hidden" in names

    assert tools
           |> Enum.find(&(Tool.name(&1) == "visible"))
           |> Tool.description() == "Profile description"
  end

  test "harness profile config round-trips to serializable maps and runtime profiles" do
    config =
      CapabilityProfileConfig.new(
        base_system_prompt: "Base prompt",
        system_prompt_suffix: "Suffix",
        tool_description_overrides: %{"ls" => "List files"},
        excluded_tools: ["execute"],
        excluded_middleware: ["summarization"],
        general_purpose_subagent: %{
          enabled: false,
          description: "Custom generalist",
          system_prompt: "Custom generalist prompt"
        }
      )

    assert %{
             base_system_prompt: "Base prompt",
             system_prompt_suffix: "Suffix",
             tool_description_overrides: %{"ls" => "List files"},
             excluded_tools: ["execute"],
             excluded_middleware: ["summarization"],
             general_purpose_subagent: %{
               enabled: false,
               description: "Custom generalist",
               system_prompt: "Custom generalist prompt"
             }
           } = CapabilityProfileConfig.to_map(config)

    assert CapabilityProfileConfig.from_map(CapabilityProfileConfig.to_map(config)) == config

    assert %CapabilityProfile{
             base_system_prompt: "Base prompt",
             prompt_suffix: "Suffix",
             tool_descriptions: %{"ls" => "List files"},
             excluded_tools: ["execute"],
             excluded_middleware: ["summarization"],
             default_subagent?: false,
             general_purpose_subagent: %GeneralPurposeSubagentProfile{
               description: "Custom generalist"
             }
           } = CapabilityProfileConfig.to_capability_profile(config)
  end

  test "system prompt config sets the model-visible prompt" do
    assert {:ok, agent} =
             Agent.build(
               model: %FakeChatModel{response: "done", parent: self()},
               system_prompt: "PROFILE BASE\nPROFILE SUFFIX"
             )

    assert {:ok, _state} = Agent.invoke(agent, %{messages: [Message.user("hello")]})

    assert_receive {:fake_chat_model_call, messages, _opts}
    system = Enum.find(messages, &match?(%Message{role: :system}, &1))
    assert system.content =~ "PROFILE BASE"
    assert system.content =~ "PROFILE SUFFIX"
  end

  test "explicit subagent specs control task metadata" do
    assert {:ok, agent} =
             Agent.build(
               model: %FakeChatModel{response: "done", parent: self()},
               subagents: [
                 %Spec{
                   name: "general-purpose",
                   description: "Custom GP description",
                   system_prompt: "Custom GP prompt"
                 }
               ]
             )

    assert {:ok, _state} = Agent.invoke(agent, %{messages: [Message.user("hello")]})

    assert_receive {:fake_chat_model_call, _messages, opts}

    assert opts
           |> Keyword.fetch!(:tools)
           |> Enum.find(&(Tool.name(&1) == "task"))
           |> Tool.description() =~ "Custom GP description"
  end

  test "provider profile hooks merge provider-specific model options" do
    model = %FakeChatModel{response: "done"}

    assert {^model, opts} = ProviderProfile.apply(:openai, model, temperature: 0)
    assert opts[:use_responses_api]
    assert opts[:temperature] == 0
  end

  test "provider profile registry validates, merges, and applies dynamic init options" do
    provider = "registry#{System.unique_integer([:positive])}"
    spec = "#{provider}:model"
    parent = self()

    assert_raise ArgumentError, fn ->
      ProviderProfile.register_provider_profile("#{provider}:bad:shape", ProviderProfile.new())
    end

    assert :ok =
             ProviderProfile.register_provider_profile(
               provider,
               ProviderProfile.new(
                 init_kwargs: [temperature: 0],
                 init_kwargs_factory: fn -> [parent: parent, response: "provider"] end
               )
             )

    assert :ok =
             ProviderProfile.register_provider_profile(
               spec,
               ProviderProfile.new(
                 init_kwargs: [response: "exact"],
                 pre_init: fn called_spec -> send(parent, {:provider_pre_init, called_spec}) end
               )
             )

    assert %ProviderProfile{} = ProviderProfile.get_provider_profile(spec)

    assert [
             temperature: 0,
             parent: ^parent,
             response: "caller"
           ] = ProviderProfile.apply_provider_profile(spec, response: "caller")

    assert_receive {:provider_pre_init, ^spec}
  end

  test "provider profile registry resolves exact model init options during build" do
    spec = "fake:registry-#{System.unique_integer([:positive])}"

    assert :ok =
             ProviderProfile.register_provider_profile(
               spec,
               ProviderProfile.new(init_kwargs: [response: "done", parent: self()])
             )

    assert {:ok, agent} =
             Agent.build(model: spec)

    assert {:ok, _state} = Agent.invoke(agent, %{messages: [Message.user("hello")]})

    assert_receive {:fake_chat_model_call, messages, _opts}
    assert Enum.any?(messages, &match?(%Message{role: :user, content: "hello"}, &1))
  end

  test "harness profile registry merges provider and exact model layers" do
    provider = "harness#{System.unique_integer([:positive])}"
    spec = "#{provider}:model"

    assert :ok =
             CapabilityProfile.register_capability_profile(
               provider,
               CapabilityProfile.new(
                 system_prompt_suffix: "provider suffix",
                 excluded_tools: ["execute"],
                 tool_description_overrides: %{"ls" => "provider ls"},
                 general_purpose_subagent: %{description: "provider gp"}
               )
             )

    assert :ok =
             CapabilityProfile.register_capability_profile(
               spec,
               CapabilityProfile.new(
                 tool_description_overrides: %{"grep" => "exact grep"},
                 excluded_tools: ["grep"],
                 general_purpose_subagent: %{system_prompt: "exact gp"}
               )
             )

    assert %CapabilityProfile{} = profile = CapabilityProfile.get_capability_profile(spec)
    assert profile.prompt_suffix == "provider suffix"
    assert profile.excluded_tools == ["execute", "grep"]
    assert profile.tool_descriptions == %{"grep" => "exact grep", "ls" => "provider ls"}
    assert profile.general_purpose_subagent.description == "provider gp"
    assert profile.general_purpose_subagent.system_prompt == "exact gp"
  end

  test "patch tool calls sanitizes ids, JSON args, and oversized arguments" do
    middleware = Middleware.ToolCallNormalization.new(max_argument_chars: 5)

    request =
      ModelRequest.new(
        model: %FakeChatModel{},
        messages: [],
        tools: []
      )

    response = %ModelResponse{
      messages: [
        Message.assistant("",
          tool_calls: [
            %{"id" => "bad id!", "name" => :lookup, "args" => ~s({"query":"abcdefghi"})},
            %{name: "raw", args: "not json"}
          ]
        )
      ]
    }

    assert {:ok, %ModelResponse{messages: [%Message{tool_calls: calls}]}} =
             Middleware.ToolCallNormalization.wrap_model_call(middleware, request, fn _request ->
               {:ok, response}
             end)

    assert [
             %ToolCall{
               id: "bad_id_",
               name: "lookup",
               args: %{"query" => "abcde\n\n... argument truncated at 5 bytes."}
             },
             %ToolCall{
               id: "call_1",
               name: "raw",
               args: %{"input" => "not j\n\n... argument truncated at 5 bytes."}
             }
           ] = calls
  end

  test "skills and memory middleware cache load state and inject prompts" do
    backend = State.new()

    files = %{
      "/skills/research/SKILL.md" => %Filesystem.FileData{
        encoding: "utf-8",
        content: "---\nname: research\ndescription: Read sources\n---\nBody"
      },
      "/AGENTS.md" => %Filesystem.FileData{
        encoding: "utf-8",
        content: "Keep notes concise.<!-- hidden -->"
      }
    }

    skills = Middleware.Skills.new(backend: backend, skills: ["/skills/research"])
    memory = Middleware.Memory.new(backend: backend)

    assert %{
             skills_metadata: [%{name: "research", description: "Read sources"}],
             skills_load_errors: []
           } = Middleware.Skills.before_model(skills, %{files: files}, %{})

    assert %{memory_contents: %{"/AGENTS.md" => "Keep notes concise.<!-- hidden -->"}} =
             Middleware.Memory.before_model(memory, %{files: files}, %{})

    request =
      ModelRequest.new(
        state: %{
          files: files,
          skills_metadata: [%{name: "research", description: "Read sources", path: "/x"}],
          memory_contents: %{"/AGENTS.md" => "Keep notes concise.<!-- hidden -->"}
        }
      )

    assert %ModelRequest{system_message: %Message{content: skill_prompt}} =
             Middleware.Skills.wrap_model_call(skills, request, & &1)

    assert skill_prompt =~ "## Skills"
    assert skill_prompt =~ "**research**: Read sources"

    assert %ModelRequest{system_message: %Message{content: memory_prompt}} =
             Middleware.Memory.wrap_model_call(memory, request, & &1)

    assert memory_prompt =~ "<agent_memory>"
    assert memory_prompt =~ "Keep notes concise."
    refute memory_prompt =~ "<!-- hidden -->"
  end

  test "memory middleware preserves configured source order and paths in prompt" do
    backend = State.new()

    files = %{
      "/user/AGENTS.md" => %Filesystem.FileData{encoding: "utf-8", content: "User memory"},
      "/project/AGENTS.md" => %Filesystem.FileData{encoding: "utf-8", content: "Project memory"}
    }

    middleware =
      Middleware.Memory.new(backend: backend, memory: ["/user/AGENTS.md", "/project/AGENTS.md"])

    assert %{memory_contents: contents} =
             Middleware.Memory.before_model(middleware, %{files: files}, %{})

    request = ModelRequest.new(state: %{memory_contents: contents})

    assert %ModelRequest{system_message: %Message{content: prompt}} =
             Middleware.Memory.wrap_model_call(middleware, request, & &1)

    user_pos = String.split(prompt, "/user/AGENTS.md", parts: 2) |> length()
    assert prompt =~ "/user/AGENTS.md\n\nUser memory"
    assert prompt =~ "/project/AGENTS.md\n\nProject memory"
    assert :binary.match(prompt, "/user/AGENTS.md") < :binary.match(prompt, "/project/AGENTS.md")
    assert user_pos == 2
  end

  test "memory middleware passes runtime to store-backed namespace factories" do
    store = BeamWeaver.Memory.ETS.new()

    assert {:ok, _item} =
             BeamWeaver.Memory.put(store, ["users", "u1", "memories"], "AGENTS.md", %{
               "content" => "User one memory",
               "encoding" => "utf-8"
             })

    backend =
      Store.new(
        store: store,
        namespace: fn runtime -> ["users", runtime.context.user_id, "memories"] end
      )

    middleware = Middleware.Memory.new(backend: backend, memory: ["/AGENTS.md"])
    runtime = %BeamWeaver.Graph.Runtime{context: %{user_id: "u1"}, store: store}

    assert %{memory_contents: %{"/AGENTS.md" => "User one memory"}} =
             Middleware.Memory.before_model(middleware, %{}, runtime)
  end

  test "skills middleware passes runtime to store-backed namespace factories" do
    store = BeamWeaver.Memory.ETS.new()

    assert {:ok, _item} =
             BeamWeaver.Memory.put(store, ["users", "u1", "skills"], "research/SKILL.md", %{
               "content" => "---\nname: research\ndescription: User-specific research\n---\nBody",
               "encoding" => "utf-8"
             })

    backend =
      Store.new(
        store: store,
        namespace: fn runtime -> ["users", runtime.context.user_id, "skills"] end
      )

    middleware = Middleware.Skills.new(backend: backend, skills: ["/research"])
    runtime = %BeamWeaver.Graph.Runtime{context: %{user_id: "u1"}, store: store}

    assert %{skills_metadata: [%{name: "research", description: "User-specific research"}]} =
             Middleware.Skills.before_model(middleware, %{}, runtime)
  end

  test "skills middleware loads source directories with later-source override metadata" do
    backend = State.new()

    files = %{
      "/skills/base/research/SKILL.md" => %Filesystem.FileData{
        encoding: "utf-8",
        content: "---\nname: research\ndescription: Base research\n---\nBody"
      },
      "/skills/project/research/SKILL.md" => %Filesystem.FileData{
        encoding: "utf-8",
        content:
          "---\nname: research\ndescription: Project research\nlicense: MIT\nallowed-tools: read_file grep\n---\nBody"
      },
      "/skills/project/pdf/SKILL.md" => %Filesystem.FileData{
        encoding: "utf-8",
        content: "---\nname: pdf\ndescription: Parse PDFs\ncompatibility: poppler\nmetadata:\n  owner: docs\n---\nBody"
      }
    }

    middleware =
      Middleware.Skills.new(
        backend: backend,
        sources: ["/skills/base", {"/skills/project", "Project"}]
      )

    assert %{skills_metadata: skills, skills_load_errors: []} =
             Middleware.Skills.before_model(middleware, %{files: files}, %{})

    assert Enum.map(skills, & &1.name) |> Enum.sort() == ["pdf", "research"]

    assert %{
             description: "Project research",
             license: "MIT",
             allowed_tools: ["read_file", "grep"]
           } =
             Enum.find(skills, &(&1.name == "research"))

    assert %{compatibility: "poppler", metadata: %{"owner" => "docs"}} =
             Enum.find(skills, &(&1.name == "pdf"))

    request = ModelRequest.new(state: %{skills_metadata: skills, skills_load_errors: []})

    assert %ModelRequest{system_message: %Message{content: prompt}} =
             Middleware.Skills.wrap_model_call(middleware, request, & &1)

    assert prompt =~ "**Project Skills**: `/skills/project` (higher priority)"
    assert prompt =~ "**research**: Project research"
    assert prompt =~ "Allowed tools: read_file, grep"
    assert prompt =~ "Read `/skills/project/research/SKILL.md`"
  end

  test "task subagent forwards non-private parent state and returns merge command" do
    middleware =
      Middleware.Subagents.new(
        model: %FakeChatModel{response: "child done", parent: self()},
        subagents: [
          %Spec{
            name: "worker",
            description: "Worker",
            system_prompt: "You are a worker."
          }
        ]
      )

    task_tool = middleware |> Middleware.Subagents.tools() |> hd()

    parent_state = %{
      messages: [Message.user("parent message")],
      files: %{"/note.txt" => %Filesystem.FileData{content: "shared", encoding: "utf-8"}},
      memory_contents: "private memory"
    }

    assert {:ok, %Command{update: update}} =
             Tool.invoke(task_tool, %{
               "subagent_type" => "worker",
               "description" => "do child work",
               state: parent_state,
               runtime: %{
                 context: %{tenant: "acme"},
                 config: %{configurable: %{thread_id: "parent"}}
               },
               tool_call_id: "call-task"
             })

    assert %{
             messages: [
               %Message{
                 role: :tool,
                 content: "child done",
                 tool_call_id: "call-task",
                 metadata: metadata
               }
             ]
           } =
             update

    assert metadata.subagent_name == "worker"

    assert_receive {:fake_chat_model_call, messages, opts}
    assert Enum.any?(messages, &match?(%Message{role: :user, content: "do child work"}, &1))
    refute Enum.any?(messages, &match?(%Message{content: "parent message"}, &1))
    assert opts[:context] == %{tenant: "acme"}
  end

  test "task subagent accepts subagent_type and child agents get DeepAgents base tools" do
    middleware =
      Middleware.Subagents.new(
        model: %FakeChatModel{response: "typed child done", parent: self()},
        summarization: false,
        subagents: [
          %Spec{
            name: "worker",
            description: "Worker",
            system_prompt: "You are a worker.",
            base_middleware: [:deepagents]
          }
        ]
      )

    task_tool = middleware |> Middleware.Subagents.tools() |> hd()

    assert {:ok, %Command{update: %{messages: [%Message{content: "typed child done"}]}}} =
             Tool.invoke(task_tool, %{
               "subagent_type" => "worker",
               "description" => "do typed child work",
               state: %{},
               tool_call_id: "call-task-type"
             })

    assert_receive {:fake_chat_model_call, _messages, opts}
    tool_names = opts |> Keyword.fetch!(:tools) |> Enum.map(&Tool.name/1)

    assert "write_todos" in tool_names
    assert "read_file" in tool_names
    assert "write_file" in tool_names
  end

  test "task subagent can inherit parent messages without copying them through task input" do
    middleware =
      Middleware.Subagents.new(
        model: %FakeChatModel{response: "child saw context", parent: self()},
        summarization: false,
        compact_conversation: false,
        subagents: [
          %Spec{
            name: "worker",
            description: "Worker",
            system_prompt: "You are a worker.",
            inherit_messages: true,
            base_middleware: []
          }
        ]
      )

    task_tool = middleware |> Middleware.Subagents.tools() |> hd()

    assert {:ok, %Command{update: %{messages: [%Message{content: "child saw context"}]}}} =
             Tool.invoke(task_tool, %{
               "subagent_type" => "worker",
               "description" => "use the inherited source context",
               state: %{messages: [Message.user("parent source context")]},
               tool_call_id: "call-inherit"
             })

    assert_receive {:fake_chat_model_call, messages, _opts}
    assert Enum.any?(messages, &match?(%Message{role: :user, content: "parent source context"}, &1))
    assert Enum.any?(messages, &match?(%Message{role: :user, content: "use the inherited source context"}, &1))
  end

  test "inherited subagent messages exclude parent tool protocol messages" do
    middleware =
      Middleware.Subagents.new(
        model: %FakeChatModel{response: "child saw clean context", parent: self()},
        summarization: false,
        compact_conversation: false,
        subagents: [
          %Spec{
            name: "worker",
            description: "Worker",
            system_prompt: "You are a worker.",
            inherit_messages: true,
            base_middleware: []
          }
        ]
      )

    task_tool = middleware |> Middleware.Subagents.tools() |> hd()

    parent_call =
      BeamWeaver.Core.Messages.tool_call(
        id: "call-parent-task",
        name: "task",
        args: %{"subagent_type" => "worker", "description" => "parent task"}
      )

    parent_messages = [
      Message.user("parent source context"),
      Message.assistant("", tool_calls: [parent_call]),
      Message.tool("prior task result", name: "task", tool_call_id: "call-parent-task"),
      Message.assistant("stable parent answer")
    ]

    assert {:ok, %Command{update: %{messages: [%Message{content: "child saw clean context"}]}}} =
             Tool.invoke(task_tool, %{
               "subagent_type" => "worker",
               "description" => "use inherited context without parent task protocol",
               state: %{messages: parent_messages},
               tool_call_id: "call-inherit-clean"
             })

    assert_receive {:fake_chat_model_call, messages, _opts}
    assert Enum.any?(messages, &match?(%Message{role: :user, content: "parent source context"}, &1))
    assert Enum.any?(messages, &match?(%Message{role: :assistant, content: "stable parent answer"}, &1))

    assert Enum.any?(
             messages,
             &match?(%Message{role: :user, content: "use inherited context without parent task protocol"}, &1)
           )

    refute Enum.any?(messages, &match?(%Message{role: :tool}, &1))

    refute Enum.any?(messages, fn
             %Message{role: :assistant, tool_calls: calls} -> calls != []
             _message -> false
           end)
  end

  test "captured task subagent stores structured output and returns a compact ack" do
    middleware =
      Middleware.Subagents.new(
        model: %FakeChatModel{
          structured_response: %{"answer" => "42", "facts" => [%{"label" => "budget", "value" => "known"}]},
          profile: %{structured_output: true},
          parent: self()
        },
        summarization: false,
        compact_conversation: false,
        subagents: [
          %Spec{
            name: "worker",
            description: "Worker",
            system_prompt: "You are a worker.",
            response_format: worker_output_schema(),
            capture_output: :worker_output,
            execution_mode: :structured_once,
            base_middleware: [],
            tools: []
          }
        ]
      )

    task_tool = middleware |> Middleware.Subagents.tools() |> hd()

    assert {:ok, %Command{update: update}} =
             Tool.invoke(task_tool, %{
               "subagent_type" => "worker",
               "description" => "return structured output",
               state: %{},
               tool_call_id: "call-capture"
             })

    assert update.subagent_outputs == %{
             "worker_output" => %{
               "answer" => "42",
               "facts" => [%{"label" => "budget", "value" => "known"}]
             }
           }

    assert [%Message{content: content, metadata: metadata}] = update.messages

    assert content == "{}"
    refute content =~ "budget"
    assert metadata.capture_key == "worker_output"
    assert metadata.cache_hit == false
    assert metadata.execution_mode == :structured_once
    assert metadata.structured_output_strategy == :provider

    assert_receive {:fake_chat_model_call, _messages, opts}
    assert Keyword.fetch!(opts, :tools) == []
    assert Keyword.fetch!(opts, :response_format).name == "WorkerOutput"
  end

  test "parallel captured task calls preserve all captured outputs" do
    middleware =
      Middleware.Subagents.new(
        model: %BeamWeaver.AgentCapabilitiesTest.InputEchoStructuredModel{parent: self()},
        summarization: false,
        compact_conversation: false,
        subagents: [
          %Spec{
            name: "first_worker",
            description: "First worker",
            system_prompt: "You are the first worker.",
            response_format: worker_output_schema(),
            capture_output: :first_output,
            execution_mode: :structured_once,
            base_middleware: [],
            tools: []
          },
          %Spec{
            name: "second_worker",
            description: "Second worker",
            system_prompt: "You are the second worker.",
            response_format: worker_output_schema(),
            capture_output: :second_output,
            execution_mode: :structured_once,
            base_middleware: [],
            tools: []
          }
        ]
      )

    task_tool = middleware |> Middleware.Subagents.tools() |> hd()
    node = ToolNode.new([task_tool], timeout: 30_000)

    first_call =
      BeamWeaver.Core.Messages.tool_call(
        id: "call-first-worker",
        name: "task",
        args: %{"subagent_type" => "first_worker", "description" => "first input"}
      )

    second_call =
      BeamWeaver.Core.Messages.tool_call(
        id: "call-second-worker",
        name: "task",
        args: %{"subagent_type" => "second_worker", "description" => "second input"}
      )

    assert %Command{update: update} =
             ToolNode.invoke(%{node | timeout: 30_000}, %{
               messages: [Message.assistant("", tool_calls: [first_call, second_call])]
             })

    assert update.subagent_outputs == %{
             "first_output" => %{"answer" => "first", "facts" => []},
             "second_output" => %{"answer" => "second", "facts" => []}
           }

    assert [
             %Message{content: first_ack, metadata: first_metadata},
             %Message{content: second_ack, metadata: second_metadata}
           ] =
             update.messages

    assert first_ack == "{}"
    assert second_ack == "{}"
    assert first_metadata.capture_key == "first_output"
    assert second_metadata.capture_key == "second_output"

    assert_receive {:input_echo_structured_call, "first"}
    assert_receive {:input_echo_structured_call, "second"}
  end

  test "captured task subagent dedupes repeated calls by input hash" do
    middleware =
      Middleware.Subagents.new(
        model: %FakeChatModel{
          structured_response: %{"answer" => "cached", "facts" => []},
          profile: %{structured_output: true},
          parent: self()
        },
        summarization: false,
        compact_conversation: false,
        subagents: [
          %Spec{
            name: "worker",
            description: "Worker",
            system_prompt: "You are a worker.",
            response_format: worker_output_schema(),
            capture_output: :worker_output,
            execution_mode: :structured_once,
            base_middleware: [],
            tools: []
          }
        ]
      )

    task_tool = middleware |> Middleware.Subagents.tools() |> hd()
    args = %{"subagent_type" => "worker", "description" => "same input"}

    assert {:ok, %Command{update: first_update}} =
             Tool.invoke(task_tool, Map.merge(args, %{state: %{}, tool_call_id: "call-capture-1"}))

    assert_receive {:fake_chat_model_call, _messages, _opts}

    assert {:ok, %Command{update: second_update}} =
             Tool.invoke(
               task_tool,
               Map.merge(args, %{
                 state: %{
                   subagent_outputs: first_update.subagent_outputs,
                   subagent_cache: first_update.subagent_cache
                 },
                 tool_call_id: "call-capture-2"
               })
             )

    assert [%Message{content: "{}", metadata: metadata}] = second_update.messages
    assert metadata.cache_hit == true
    assert metadata.capture_key == "worker_output"

    refute_receive {:fake_chat_model_call, _messages, _opts}, 50
  end

  test "captured task subagent cache keeps per-input snapshots when capture key is reused" do
    middleware =
      Middleware.Subagents.new(
        model: %BeamWeaver.AgentCapabilitiesTest.InputEchoStructuredModel{parent: self()},
        summarization: false,
        compact_conversation: false,
        subagents: [
          %Spec{
            name: "worker",
            description: "Worker",
            system_prompt: "You are a worker.",
            response_format: worker_output_schema(),
            capture_output: [key: :worker_output, parent_result: :full],
            execution_mode: :structured_once,
            base_middleware: [],
            tools: []
          }
        ]
      )

    task_tool = middleware |> Middleware.Subagents.tools() |> hd()

    assert {:ok, %Command{update: first_update}} =
             Tool.invoke(task_tool, %{
               "subagent_type" => "worker",
               "description" => "first input",
               state: %{},
               tool_call_id: "call-first"
             })

    assert {:ok, %Command{update: second_update}} =
             Tool.invoke(task_tool, %{
               "subagent_type" => "worker",
               "description" => "second input",
               state: %{
                 subagent_outputs: first_update.subagent_outputs,
                 subagent_cache: first_update.subagent_cache
               },
               tool_call_id: "call-second"
             })

    merged_state = %{
      subagent_outputs: Map.merge(first_update.subagent_outputs, second_update.subagent_outputs),
      subagent_cache: Map.merge(first_update.subagent_cache, second_update.subagent_cache)
    }

    assert {:ok, %Command{update: cached_update}} =
             Tool.invoke(task_tool, %{
               "subagent_type" => "worker",
               "description" => "first input",
               state: merged_state,
               tool_call_id: "call-first-again"
             })

    assert %{"answer" => "first", "facts" => []} =
             cached_update.messages |> hd() |> Map.fetch!(:content) |> BeamWeaver.JSON.decode!()

    assert cached_update.subagent_outputs == %{
             "worker_output" => %{"answer" => "first", "facts" => []}
           }

    assert_receive {:input_echo_structured_call, "first"}
    assert_receive {:input_echo_structured_call, "second"}
    refute_receive {:input_echo_structured_call, "first"}, 50
  end

  test "task subagent does not inherit captured state restored with string keys" do
    middleware =
      Middleware.Subagents.new(
        model: %FakeChatModel{structured_response: %{"answer" => "ok", "facts" => []}},
        summarization: false,
        compact_conversation: false,
        subagents: [
          %Spec{
            name: "worker",
            description: "Worker",
            system_prompt: "You are a worker.",
            response_format: worker_output_schema(),
            capture_output: :worker_output,
            execution_mode: :structured_once,
            base_middleware: [],
            tools: [],
            middleware: [
              {BeamWeaver.AgentCapabilitiesTest.ChildStateRecorderMiddleware, parent: self()}
            ]
          }
        ]
      )

    task_tool = middleware |> Middleware.Subagents.tools() |> hd()

    assert {:ok, %Command{}} =
             Tool.invoke(task_tool, %{
               "subagent_type" => "worker",
               "description" => "inspect child state",
               state: %{
                 "subagent_outputs" => %{"worker_output" => %{"answer" => "old"}},
                 "subagent_cache" => %{"worker:old" => %{"output" => %{"answer" => "old"}}}
               },
               tool_call_id: "call-state"
             })

    assert_receive {:child_subagent_state, child_state}
    refute Map.has_key?(child_state, :subagent_outputs)
    refute Map.has_key?(child_state, "subagent_outputs")
    refute Map.has_key?(child_state, :subagent_cache)
    refute Map.has_key?(child_state, "subagent_cache")
  end

  test "captured task subagent can preserve full parent result when requested" do
    middleware =
      Middleware.Subagents.new(
        model: %FakeChatModel{
          structured_response: %{"answer" => "full", "facts" => []},
          profile: %{structured_output: true}
        },
        summarization: false,
        compact_conversation: false,
        subagents: [
          %Spec{
            name: "worker",
            description: "Worker",
            system_prompt: "You are a worker.",
            response_format: worker_output_schema(),
            capture_output: [key: :worker_output, parent_result: :full],
            execution_mode: :structured_once,
            base_middleware: [],
            tools: []
          }
        ]
      )

    task_tool = middleware |> Middleware.Subagents.tools() |> hd()

    assert {:ok, %Command{update: %{messages: [%Message{content: content}], subagent_outputs: outputs}}} =
             Tool.invoke(task_tool, %{
               "subagent_type" => "worker",
               "description" => "return full output",
               state: %{},
               tool_call_id: "call-capture-full"
             })

    assert %{"answer" => "full", "facts" => []} = BeamWeaver.JSON.decode!(content)
    assert outputs["worker_output"]["answer"] == "full"
  end

  test "research_then_generate runs tool research before one structured generation pass" do
    lookup =
      Tool.from_function!(
        name: "lookup",
        description: "Lookup deal context.",
        input_schema: %{
          "type" => "object",
          "required" => ["query"],
          "properties" => %{"query" => %{"type" => "string"}}
        },
        handler: fn %{"query" => query}, _opts -> "lookup result for #{query}" end
      )

    middleware =
      Middleware.Subagents.new(
        model: %BeamWeaver.AgentCapabilitiesTest.ResearchThenGenerateModel{parent: self()},
        summarization: false,
        compact_conversation: false,
        subagents: [
          %Spec{
            name: "worker",
            description: "Worker",
            system_prompt: "You are a worker.",
            tools: [lookup],
            base_middleware: [:deepagents],
            response_format: BeamWeaver.Agent.StructuredOutput.provider(worker_output_schema()),
            capture_output: :worker_output,
            execution_mode: :research_then_generate
          }
        ]
      )

    task_tool = middleware |> Middleware.Subagents.tools() |> hd()

    assert {:ok, %Command{update: %{messages: [%Message{content: ack, metadata: metadata}], subagent_outputs: outputs}}} =
             Tool.invoke(task_tool, %{
               "subagent_type" => "worker",
               "description" => "research then answer",
               state: %{},
               tool_call_id: "call-research-generate"
             })

    assert ack == "{}"
    assert metadata.capture_key == "worker_output"
    assert outputs["worker_output"] == %{"answer" => "generated", "facts" => []}

    assert_receive {:research_then_generate_call, [:system, :user], research_tools, false}
    assert "lookup" in research_tools
    assert "write_todos" in research_tools
    assert "read_file" in research_tools

    assert_receive {:research_then_generate_call, [:system, :user, :assistant, :tool], research_tools, false}
    assert "lookup" in research_tools
    assert_receive {:research_then_generate_call, [:system, :user], [], true}
  end

  test "research_then_generate generate pass does not inherit parent transcript" do
    lookup =
      Tool.from_function!(
        name: "lookup",
        description: "Lookup deal context.",
        input_schema: %{
          "type" => "object",
          "required" => ["query"],
          "properties" => %{"query" => %{"type" => "string"}}
        },
        handler: fn %{"query" => query}, _opts -> "lookup result for #{query}" end
      )

    middleware =
      Middleware.Subagents.new(
        model: %BeamWeaver.AgentCapabilitiesTest.ResearchThenGenerateModel{parent: self()},
        summarization: false,
        compact_conversation: false,
        subagents: [
          %Spec{
            name: "worker",
            description: "Worker",
            system_prompt: "You are a worker.",
            tools: [lookup],
            response_format: BeamWeaver.Agent.StructuredOutput.provider(worker_output_schema()),
            capture_output: :worker_output,
            execution_mode: :research_then_generate,
            inherit_messages: true
          }
        ]
      )

    task_tool = middleware |> Middleware.Subagents.tools() |> hd()

    assert {:ok, %Command{update: %{subagent_outputs: outputs}}} =
             Tool.invoke(task_tool, %{
               "subagent_type" => "worker",
               "description" => "research then answer",
               state: %{messages: [Message.user("large parent context")]},
               tool_call_id: "call-research-generate"
             })

    assert outputs["worker_output"] == %{"answer" => "generated", "facts" => []}

    assert_receive {:research_then_generate_call, [:system, :user, :user], _research_tools, false}
    assert_receive {:research_then_generate_call, [:system, :user, :user, :assistant, :tool], _research_tools, false}
    assert_receive {:research_then_generate_call, [:system, :user], [], true}
  end

  test "subagent default composition has no implicit filesystem or todo tools" do
    middleware =
      Middleware.Subagents.new(
        model: %FakeChatModel{response: "plain child done", parent: self()},
        summarization: false,
        compact_conversation: false,
        subagents: [
          %Spec{
            name: "worker",
            description: "Worker",
            system_prompt: "You are a worker.",
            tools: []
          }
        ]
      )

    task_tool = middleware |> Middleware.Subagents.tools() |> hd()

    assert {:ok, %Command{update: %{messages: [%Message{content: "plain child done"}]}}} =
             Tool.invoke(task_tool, %{
               "subagent_type" => "worker",
               "description" => "no base tools",
               state: %{},
               tool_call_id: "call-no-base"
             })

    assert_receive {:fake_chat_model_call, _messages, opts}
    assert Keyword.fetch!(opts, :tools) == []
  end

  test "task subagent preserves checkpoint config and writes under an isolated namespace" do
    checkpointer = Checkpoint.ETS.new()

    middleware =
      Middleware.Subagents.new(
        model: %FakeChatModel{response: "checkpointed child done"},
        summarization: false,
        compact_conversation: false,
        checkpointer: checkpointer,
        subagents: [
          %Spec{
            name: "worker",
            description: "Worker",
            system_prompt: "You are a worker."
          }
        ]
      )

    task_tool = middleware |> Middleware.Subagents.tools() |> hd()

    assert {:ok, %Command{update: %{messages: [%Message{content: "checkpointed child done"}]}}} =
             Tool.invoke(task_tool, %{
               "subagent_type" => "worker",
               "description" => "do checkpointed child work",
               state: %{},
               runtime: %{
                 node: "tools",
                 task_id: "tool-node-task",
                 config: %{
                   "configurable" => %{
                     "thread_id" => "subagent-thread",
                     "checkpoint_map" => %{}
                   }
                 }
               },
               tool_call_id: "call-task-checkpoint"
             })

    records = Checkpoint.list(checkpointer, %{"configurable" => %{"thread_id" => "subagent-thread"}})
    namespaces = Enum.map(records, &get_in(&1.config, ["configurable", "checkpoint_ns"]))

    assert records != []
    refute "" in namespaces
    assert Enum.any?(namespaces, &String.contains?(&1, "subagent.worker"))
  end

  test "task subagent recovers checkpoint config from tool runtime execution info" do
    checkpointer = Checkpoint.ETS.new()

    middleware =
      Middleware.Subagents.new(
        model: %FakeChatModel{response: "checkpointed child done"},
        summarization: false,
        compact_conversation: false,
        checkpointer: checkpointer,
        subagents: [
          %Spec{
            name: "worker",
            description: "Worker",
            system_prompt: "You are a worker."
          }
        ]
      )

    task_tool = middleware |> Middleware.Subagents.tools() |> hd()

    tool_runtime = %ToolRuntime{
      config: %{"configurable" => %{}},
      execution_info: %ExecutionInfo{
        thread_id: "subagent-execution-thread",
        checkpoint_ns: "",
        checkpoint_id: "parent-checkpoint",
        task_id: "tool-node-task"
      }
    }

    assert {:ok, %Command{update: %{messages: [%Message{content: "checkpointed child done"}]}}} =
             Tool.invoke(task_tool, %{
               "subagent_type" => "worker",
               "description" => "do checkpointed child work",
               state: %{},
               tool_runtime: tool_runtime,
               tool_call_id: "call-task-checkpoint"
             })

    records =
      Checkpoint.list(checkpointer, %{
        "configurable" => %{"thread_id" => "subagent-execution-thread"}
      })

    namespaces = Enum.map(records, &get_in(&1.config, ["configurable", "checkpoint_ns"]))

    assert records != []
    refute "" in namespaces
    assert Enum.any?(namespaces, &String.contains?(&1, "subagent.worker"))
  end

  test "task subagent parent command excludes child string-keyed messages and todos" do
    child_graph =
      Graph.new(name: "StringKeyedChild")
      |> Graph.add_node(:done, fn _state ->
        %{
          "messages" => [Message.assistant("child result")],
          "todos" => [%{"text" => "child todo"}],
          "custom_child_value" => "kept"
        }
      end)
      |> Graph.add_edge(Graph.start(), :done)
      |> Graph.compile!()

    child_agent = %Built{
      spec: %BeamWeaver.Agent.Spec{name: "string-keyed-child"},
      compiled: child_graph
    }

    middleware =
      Middleware.Subagents.new(
        model: %FakeChatModel{response: "unused"},
        summarization: false,
        compact_conversation: false,
        subagents: [
          %BeamWeaver.Agent.Subagent.Compiled{
            name: "worker",
            description: "Worker",
            agent: child_agent
          }
        ]
      )

    task_tool = middleware |> Middleware.Subagents.tools() |> hd()
    node = ToolNode.new([task_tool], timeout: 30_000)

    call =
      BeamWeaver.Core.Messages.tool_call(
        id: "call-task",
        name: "task",
        args: %{"subagent_type" => "worker", "description" => "do child work"}
      )

    state = %{messages: [Message.user("parent"), Message.assistant("", tool_calls: [call])]}

    assert %Command{update: update} =
             ToolNode.invoke(node, state, %Runtime{
               config: %{"configurable" => %{"thread_id" => "parent-thread"}},
               node: "tools",
               task_id: "tool-node-task"
             })

    refute Map.has_key?(update, "messages")
    refute Map.has_key?(update, "todos")
    assert update["custom_child_value"] == "kept"
    assert %{messages: [%Message{name: "task", content: "child result"}]} = update
  end

  test "subagent middleware injects task guidance and available agent names" do
    middleware =
      Middleware.Subagents.new(
        model: %FakeChatModel{response: "child done"},
        summarization: false,
        subagents: [
          %Spec{
            name: "worker",
            description: "Worker description",
            system_prompt: "You are a worker."
          }
        ]
      )

    request = ModelRequest.new(system_prompt: "base")

    assert %ModelRequest{system_message: %Message{content: prompt}} =
             Middleware.Subagents.wrap_model_call(middleware, request, & &1)

    assert prompt =~ "base"
    assert prompt =~ "`task`"
    assert prompt =~ "Available subagent types"
    assert prompt =~ "worker: Worker description"
  end

  test "subagent middleware validates specs and requires atom-key maps" do
    default_middleware =
      Middleware.Subagents.new(model: %FakeChatModel{response: "unused"}, subagents: [])

    [default_task_tool] = Middleware.Subagents.tools(default_middleware)
    assert Tool.description(default_task_tool) =~ "general-purpose"
    assert Tool.input_schema(default_task_tool)["required"] == ["description", "subagent_type"]

    assert_raise ArgumentError, ~r/duplicate subagent names/, fn ->
      Middleware.Subagents.new(
        model: %FakeChatModel{response: "unused"},
        subagents: [
          %Spec{name: "dup", description: "One", system_prompt: "One"},
          %Spec{name: "dup", description: "Two", system_prompt: "Two"}
        ]
      )
    end

    middleware =
      Middleware.Subagents.new(
        model: %FakeChatModel{response: "child done"},
        summarization: false,
        subagents: [
          %{
            name: "atom-worker",
            description: "Atom-key worker",
            system_prompt: "You are a worker."
          }
        ]
      )

    [task_tool] = Middleware.Subagents.tools(middleware)
    assert Tool.description(task_tool) =~ "atom-worker: Atom-key worker"

    assert_raise ArgumentError,
                 ~r/subagent spec options must use atom keys, got "(name|description|system_prompt)"/,
                 fn ->
                   Middleware.Subagents.new(
                     model: %FakeChatModel{response: "child done"},
                     summarization: false,
                     subagents: [
                       %{
                         "name" => "json-worker",
                         "description" => "String-key worker",
                         "system_prompt" => "You are a worker."
                       }
                     ]
                   )
                 end

    assert_raise ArgumentError, ~r/unknown subagent execution_mode "structured_once"/, fn ->
      Middleware.Subagents.new(
        model: %FakeChatModel{response: "child done"},
        summarization: false,
        subagents: [
          %Spec{
            name: "worker",
            description: "Worker",
            system_prompt: "You are a worker.",
            execution_mode: "structured_once"
          }
        ]
      )
    end

    assert_raise ArgumentError, ~s/invalid capture_output "worker_output"/, fn ->
      Middleware.Subagents.new(
        model: %FakeChatModel{response: "child done"},
        summarization: false,
        subagents: [
          %Spec{
            name: "worker",
            description: "Worker",
            system_prompt: "You are a worker.",
            capture_output: "worker_output"
          }
        ]
      )
    end

    assert_raise ArgumentError, ~r/invalid capture_output parent_result "full"/, fn ->
      Middleware.Subagents.new(
        model: %FakeChatModel{response: "child done"},
        summarization: false,
        subagents: [
          %Spec{
            name: "worker",
            description: "Worker",
            system_prompt: "You are a worker.",
            capture_output: [key: :worker_output, parent_result: "full"]
          }
        ]
      )
    end

    assert_raise ArgumentError, ~s/base_middleware entries must use atom or module values, got "deepagents"/, fn ->
      Middleware.Subagents.new(
        model: %FakeChatModel{response: "child done"},
        summarization: false,
        subagents: [
          %Spec{
            name: "worker",
            description: "Worker",
            system_prompt: "You are a worker.",
            base_middleware: ["deepagents"]
          }
        ]
      )
    end
  end

  test "async subagent tools update task state through graph commands" do
    assert_raise ArgumentError, ~r/async subagent spec options must use atom keys, got "(name|description)"/, fn ->
      AsyncSpec.new(%{"name" => "research", "description" => "Research"})
    end

    middleware =
      Middleware.AsyncSubagents.new(
        subagents: [
          %AsyncSpec{
            name: "research",
            description: "Research",
            graph_id: "graph",
            url: "http://agent"
          }
        ]
      )

    tools = Middleware.AsyncSubagents.tools(middleware)
    start_tool = Enum.find(tools, &(Tool.name(&1) == "start_async_task"))
    update_tool = Enum.find(tools, &(Tool.name(&1) == "update_async_task"))
    cancel_tool = Enum.find(tools, &(Tool.name(&1) == "cancel_async_task"))
    check_tool = Enum.find(tools, &(Tool.name(&1) == "check_async_task"))

    assert {:ok, %Command{update: %{async_tasks: tasks}}} =
             Tool.invoke(start_tool, %{
               "subagent_type" => "research",
               "description" => "Find references",
               state: %{},
               tool_call_id: "call-start"
             })

    [task_id] = Map.keys(tasks)

    assert {:ok, %Command{update: %{async_tasks: updated}}} =
             Tool.invoke(update_tool, %{
               "task_id" => task_id,
               "message" => "New detail",
               state: %{async_tasks: tasks},
               tool_call_id: "call-update"
             })

    assert [%{message: "New detail"}] = updated[task_id].updates

    assert {:ok, %Command{update: %{async_tasks: cancelled}}} =
             Tool.invoke(cancel_tool, %{
               "task_id" => task_id,
               state: %{async_tasks: updated},
               tool_call_id: "call-cancel"
             })

    assert cancelled[task_id].status == "cancelled"

    assert {:ok, encoded} =
             Tool.invoke(check_tool, %{"task_id" => task_id, state: %{async_tasks: cancelled}})

    assert %{"status" => "cancelled"} = BeamWeaver.JSON.decode!(encoded)
  end

  test "async subagent tools can call a minimal Agent Protocol client" do
    middleware =
      Middleware.AsyncSubagents.new(
        subagents: [
          AsyncSpec.new(
            name: "remote",
            description: "Remote",
            graph_id: "graph",
            url: "http://agent",
            client: BeamWeaver.AgentCapabilitiesTest.AsyncClientFake
          )
        ]
      )

    tools = Middleware.AsyncSubagents.tools(middleware)
    start_tool = Enum.find(tools, &(Tool.name(&1) == "start_async_task"))
    check_tool = Enum.find(tools, &(Tool.name(&1) == "check_async_task"))

    assert {:ok, %Command{update: %{async_tasks: %{"remote-run" => task}}}} =
             Tool.invoke(start_tool, %{
               "subagent_type" => "remote",
               "description" => "Find references",
               state: %{},
               tool_call_id: "call-start"
             })

    assert task.status == "running"
    assert task.remote["assistant_id"] == "graph"

    assert {:ok, %Command{update: %{async_tasks: %{"remote-run" => checked}}}} =
             Tool.invoke(check_tool, %{
               "task_id" => "remote-run",
               state: %{async_tasks: %{"remote-run" => task}},
               tool_call_id: "call-check"
             })

    assert checked.status == "complete"
    assert checked.remote["result"] == "done"
  end

  test "async subagent check extracts final result from thread values" do
    middleware =
      Middleware.AsyncSubagents.new(
        subagents: [
          AsyncSpec.new(
            name: "remote",
            description: "Remote",
            graph_id: "graph",
            url: "http://agent",
            client: BeamWeaver.AgentCapabilitiesTest.AsyncClientThreadFake
          )
        ]
      )

    tools = Middleware.AsyncSubagents.tools(middleware)
    start_tool = Enum.find(tools, &(Tool.name(&1) == "start_async_task"))
    check_tool = Enum.find(tools, &(Tool.name(&1) == "check_async_task"))

    assert {:ok, %Command{update: %{async_tasks: %{"thread-1" => task}}}} =
             Tool.invoke(start_tool, %{
               "subagent_type" => "remote",
               "description" => "Find references",
               state: %{},
               tool_call_id: "call-start"
             })

    assert {:ok, %Command{update: %{async_tasks: %{"thread-1" => checked}}}} =
             Tool.invoke(check_tool, %{
               "task_id" => "thread-1",
               state: %{async_tasks: %{"thread-1" => task}},
               tool_call_id: "call-check"
             })

    assert checked.status == "success"
    assert checked.result == "final output"
  end

  test "async subagent list tool refreshes live statuses and writes task state" do
    middleware =
      Middleware.AsyncSubagents.new(
        subagents: [
          AsyncSpec.new(
            name: "remote",
            description: "Remote",
            graph_id: "graph",
            url: "http://agent",
            client: BeamWeaver.AgentCapabilitiesTest.AsyncClientFake
          )
        ]
      )

    list_tool =
      middleware
      |> Middleware.AsyncSubagents.tools()
      |> Enum.find(&(Tool.name(&1) == "list_async_tasks"))

    task = %{
      id: "remote-run",
      task_id: "remote-run",
      subagent_name: "remote",
      status: "running",
      created_at: "2026-05-25T00:00:00Z",
      last_checked_at: "2026-05-25T00:00:00Z",
      last_updated_at: "2026-05-25T00:00:00Z"
    }

    assert {:ok, %Command{update: %{async_tasks: %{"remote-run" => updated}, messages: [msg]}}} =
             Tool.invoke(list_tool, %{
               "status_filter" => "all",
               state: %{async_tasks: %{"remote-run" => task}},
               tool_call_id: "call-list"
             })

    assert updated.status == "complete"
    assert updated.remote["result"] == "done"
    assert msg.content =~ "1 tracked task"
    assert msg.content =~ "remote-run"
  end

  test "async subagent middleware injects guidance and validates duplicate names" do
    middleware =
      Middleware.AsyncSubagents.new(
        subagents: [
          %AsyncSpec{
            name: "remote",
            description: "Remote worker",
            graph_id: "graph"
          }
        ]
      )

    request = ModelRequest.new(system_prompt: "base")

    assert %ModelRequest{system_message: %Message{content: prompt}} =
             Middleware.AsyncSubagents.wrap_model_call(middleware, request, & &1)

    assert prompt =~ "base"
    assert prompt =~ "Async subagents"
    assert prompt =~ "remote: Remote worker"

    assert_raise ArgumentError, ~r/duplicate async subagent names/, fn ->
      Middleware.AsyncSubagents.new(
        subagents: [
          %AsyncSpec{name: "dup", description: "One", graph_id: "one"},
          %AsyncSpec{name: "dup", description: "Two", graph_id: "two"}
        ]
      )
    end
  end

  test "create/1 routes AsyncSpec entries from subagents option to async tools" do
    assert {:ok, agent} =
             Agent.build(
               model: %FakeChatModel{response: "done", parent: self()},
               summarization: false,
               subagents: [
                 %AsyncSpec{
                   name: "remote",
                   description: "Remote worker",
                   graph_id: "graph"
                 }
               ]
             )

    assert {:ok, _state} = Agent.invoke(agent, %{messages: [Message.user("hello")]})

    assert_receive {:fake_chat_model_call, _messages, opts}
    tool_names = opts |> Keyword.fetch!(:tools) |> Enum.map(&Tool.name/1)

    assert "start_async_task" in tool_names
    assert "list_async_tasks" in tool_names
  end

  defp tmp_root do
    root =
      Path.join([
        System.tmp_dir!(),
        "beam_weaver_deepagents_#{System.unique_integer([:positive])}"
      ])

    File.rm_rf!(root)
    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf!(root) end)

    root
  end

  defp worker_output_schema do
    %{
      "title" => "WorkerOutput",
      "type" => "object",
      "required" => ["answer", "facts"],
      "properties" => %{
        "answer" => %{"type" => "string"},
        "facts" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "required" => ["label", "value"],
            "properties" => %{
              "label" => %{"type" => "string"},
              "value" => %{"type" => "string"}
            }
          }
        }
      }
    }
  end
end
