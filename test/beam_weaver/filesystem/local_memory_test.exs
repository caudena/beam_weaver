defmodule BeamWeaver.Filesystem.LocalMemoryTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.ToolCall
  alias BeamWeaver.Filesystem.Local

  defmodule RememberingModel do
    @moduledoc false
    # Appends a line to /AGENTS.md when asked to remember something. Reports
    # every system prompt it is called with.
    @behaviour BeamWeaver.Core.ChatModel

    defstruct [:parent]

    @impl true
    def invoke(%__MODULE__{parent: parent}, messages, _opts) do
      send(
        parent,
        {:system_prompt, messages |> Enum.filter(&(&1.role == :system)) |> Enum.map_join("\n", &Message.text/1)}
      )

      cond do
        Enum.any?(messages, &(&1.role == :tool)) ->
          {:ok, Message.assistant("Noted.")}

        Enum.any?(messages, &(&1.role == :user and Message.text(&1) =~ "Remember")) ->
          call = %ToolCall{
            id: "call-edit",
            call_id: "call-edit",
            name: "edit_file",
            args: %{
              "file_path" => "/AGENTS.md",
              "old_string" => "- Name: Ada.",
              "new_string" => "- Name: Ada.\n- Prefers answers in German."
            }
          }

          {:ok, Message.assistant("", tool_calls: [call])}

        true ->
          {:ok, Message.assistant("Hello.")}
      end
    end
  end

  @tag :tmp_dir
  test "memory is a file on disk: the agent edits it and later conversations load it", %{tmp_dir: root} do
    memory_file = Path.join(root, "AGENTS.md")
    File.write!(memory_file, "- Name: Ada.\n")

    {:ok, agent} =
      Agent.build(
        model: %RememberingModel{parent: self()},
        filesystem: Local.new(root: root),
        memory: ["/AGENTS.md"],
        system_prompt: "You are a helpful assistant."
      )

    assert {:ok, %{messages: messages}} =
             Agent.invoke(agent, %{messages: [Message.user("Remember that I prefer answers in German.")]})

    assert Message.text(List.last(messages)) == "Noted."
    assert File.read!(memory_file) == "- Name: Ada.\n- Prefers answers in German.\n"

    # A new conversation, and an edit made outside the agent, both come from the same file.
    assert prompt_of(agent) =~ "- Prefers answers in German."

    File.write!(memory_file, "- Name: Ada.\n- Prefers answers in French.\n")
    prompt = prompt_of(agent)
    assert prompt =~ "- Prefers answers in French."
    refute prompt =~ "German"
  end

  defp prompt_of(agent) do
    flush()
    assert {:ok, _state} = Agent.invoke(agent, %{messages: [Message.user("Hello")]})
    assert_receive {:system_prompt, prompt}
    prompt
  end

  defp flush do
    receive do
      {:system_prompt, _prompt} -> flush()
    after
      0 -> :ok
    end
  end
end
