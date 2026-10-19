defmodule BeamWeaver.Agent.FilesystemMiddlewareTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent
  alias BeamWeaver.Agent.Middleware
  alias BeamWeaver.Agent.Middleware.Offload
  alias BeamWeaver.Agent.ToolCallRequest
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Filesystem.LocalShell
  alias BeamWeaver.Filesystem.State
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Models.FakeChatModel

  @moduletag :tmp_dir

  describe "the offload notice" do
    test "mentions omitted lines only when lines were omitted" do
      short =
        Offload.tool_result_notice(
          "call_1",
          "/large_tool_results/call_1",
          Enum.map_join(1..8, "\n", &"row #{&1}"),
          true
        )

      refute short =~ "lines truncated"
      assert short =~ "     8\trow 8"

      long =
        Offload.tool_result_notice(
          "call_1",
          "/large_tool_results/call_1",
          Enum.map_join(1..30, "\n", &"row #{&1}"),
          true
        )

      assert long =~ "lines of the form `... [N lines truncated] ...` indicate omitted lines"
      assert long =~ "... [20 lines truncated] ..."
    end

    test "says when long lines were cut off" do
      notice = Offload.tool_result_notice("call_1", "/large_tool_results/call_1", String.duplicate("x", 90_000), true)

      refute notice =~ "lines truncated"
      assert notice =~ "lines longer than 1,000 characters are cut off after 1,000 characters"
      assert String.ends_with?(String.trim_trailing(notice), "\t" <> String.duplicate("x", 1_000))

      refute Offload.tool_result_notice("call_1", "/large_tool_results/call_1", "row 1\nrow 2", true) =~ "cut off"
    end
  end

  test "results without a tool call id are saved under different names" do
    middleware = Middleware.Filesystem.new(backend: State.new())
    big = String.duplicate("row\n", 30_000)
    handler = fn _request -> %Message{role: :tool, content: big, tool_call_id: nil, name: "fetch"} end

    first = %ToolCallRequest{tool_call: %{name: "fetch", args: %{}}, state: %{files: %{}}}
    assert %Command{update: %{files: first_files}} = Middleware.Filesystem.wrap_tool_call(middleware, first, handler)

    second = %ToolCallRequest{tool_call: %{name: "fetch", args: %{}}, state: %{files: first_files}}

    assert %Command{update: %{files: second_files, messages: [notice]}} =
             Middleware.Filesystem.wrap_tool_call(middleware, second, handler)

    assert [first_path] = Map.keys(first_files)
    assert [second_path] = Map.keys(second_files)
    assert "/large_tool_results/" <> _id = first_path
    assert "/large_tool_results/" <> _id = second_path
    refute first_path == second_path
    assert Message.text(notice) =~ second_path
  end

  defmodule ExportOrders do
    use BeamWeaver.Tool

    name "export_orders"
    description "Export all orders as CSV."

    schema do
    end

    @impl true
    def invoke(_tool, _input, _opts), do: {:ok, String.duplicate("A-1001,shipped\n", 6_000)}
  end

  describe "an offloaded result or message" do
    test "names read_file only when the model is offered it" do
      big_message = String.duplicate("Order A-1001 arrived damaged. ", 7_000)

      for {excluded, offered?} <- [{[], true}, {["read_file"], false}] do
        {:ok, agent} =
          Agent.build(
            model: %FakeChatModel{responses: [FakeChatModel.tool_call("export_orders"), "Done."], parent: self()},
            tools: [ExportOrders],
            filesystem: State.new(),
            exclude_tools: excluded
          )

        assert {:ok, %{messages: messages}} = Agent.invoke(agent, %{messages: [big_message]})
        assert_received {:fake_chat_model_call, [_system, user], _opts}

        assert Message.text(user) =~ "Message content too large"
        assert Message.text(user) =~ "read_file" == offered?

        notice = messages |> Enum.find(&(&1.role == :tool)) |> Message.text()
        assert notice =~ "Tool result too large"
        assert notice =~ "/large_tool_results/"
        assert notice =~ "read_file" == offered?
      end
    end

    test "names read_file only when the call's tool set has it" do
      middleware = Middleware.Filesystem.new(tool_token_limit_before_evict: 2)
      big = Enum.map_join(1..12, "\n", &"row #{&1}")
      handler = fn _request -> Message.tool(big, tool_call_id: "call_1", name: "export_orders") end
      call = %{id: "call_1", name: "export_orders", args: %{}}

      for {tools, offered?} <- [
            {[ExportOrders], false},
            {[ExportOrders | Middleware.Filesystem.tools(middleware)], true}
          ] do
        request = %ToolCallRequest{tool_call: call, tool_set: BeamWeaver.Agent.ToolSet.new(tools), state: %{}}

        assert %Command{update: %{messages: [notice]}} =
                 Middleware.Filesystem.wrap_tool_call(middleware, request, handler)

        assert Message.text(notice) =~ "read_file" == offered?
      end
    end
  end

  describe "the filesystem prompt" do
    test "describes only the tools the model is offered" do
      {:ok, agent} =
        Agent.build(
          model: %FakeChatModel{responses: ["ok"], parent: self()},
          filesystem: State.new(),
          exclude_tools: ["write_file", "edit_file", "grep"]
        )

      assert {:ok, _state} = Agent.invoke(agent, %{messages: ["hi"]})
      assert_received {:fake_chat_model_call, [system | _messages], opts}

      assert opts |> Keyword.fetch!(:tools) |> Enum.map(&Tool.name/1) |> Enum.sort() == ["glob", "ls", "read_file"]

      prompt = Message.text(system)

      for hidden <- ~w(write_file edit_file grep), do: refute(prompt =~ hidden)
      assert prompt =~ "## Filesystem Tools `ls`, `read_file`, `glob`"
      assert prompt =~ "In those cases, use `read_file` to inspect the saved result in chunks."
    end

    test "says write_file replaces an existing file, and grep matches literal text" do
      {:ok, agent} = Agent.build(model: %FakeChatModel{responses: ["ok"], parent: self()}, filesystem: State.new())

      assert {:ok, _state} = Agent.invoke(agent, %{messages: ["hi"]})
      assert_received {:fake_chat_model_call, [system | _messages], _opts}

      assert Message.text(system) =~ "- write_file: create a file, or replace one"
      assert Message.text(system) =~ "- grep: search files for literal text, not a regex"
    end

    test "leaves out the execute section when execute is excluded", %{tmp_dir: dir} do
      {:ok, agent} =
        Agent.build(
          model: %FakeChatModel{responses: ["ok"], parent: self()},
          filesystem: LocalShell.new(root: dir),
          exclude_tools: ["execute"]
        )

      assert {:ok, _state} = Agent.invoke(agent, %{messages: ["hi"]})
      assert_received {:fake_chat_model_call, [system | _messages], _opts}

      prompt = Message.text(system)
      assert prompt =~ "## Filesystem Tools"
      refute prompt =~ "execute"
    end
  end
end
