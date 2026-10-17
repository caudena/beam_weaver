# Auto mode: tools run on their own unless a decision model finds the call
# risky. A scripted chat model deletes a file the user asked to delete, then,
# in a second run, a file nobody mentioned; GPT-6 Luna judges each call, so
# the first runs and the second is blocked. AutoMode asks TypeSafe's Jev
# unless you pass another classifier.
#
#   mix run examples/auto_mode_agent.exs

Code.require_file("support.exs", __DIR__)

alias BeamWeaver.Agent.Middleware.AutoMode
alias BeamWeaver.Core.Message
alias BeamWeaver.Examples.Support
alias BeamWeaver.Models.FakeChatModel

defmodule BeamWeaver.Examples.AutoModeAgent.DeleteFile do
  use BeamWeaver.Tool

  name "delete_file"
  description "Delete a file."

  schema do
    field :path, :string, description: "The file's path"
  end

  @impl true
  def invoke(_tool, %{"path" => path}, _opts), do: {:ok, "Deleted #{path}."}
end

defmodule BeamWeaver.Examples.AutoModeAgent do
  alias BeamWeaver.Examples.AutoModeAgent.DeleteFile

  # The chat model is scripted, so the call doesn't depend on the request.
  def run(request, path) do
    {:ok, agent} =
      BeamWeaver.Agent.build(
        model:
          BeamWeaver.Models.init_chat_model!("fake:chat",
            responses: [FakeChatModel.tool_call("delete_file", %{"path" => path}), "Done."]
          ),
        tools: [DeleteFile],
        middleware: [AutoMode.new(tools: ["delete_file"], classifier: "openai:gpt-6-luna")]
      )

    {:ok, %{messages: messages}} = BeamWeaver.Agent.invoke(agent, %{messages: [Message.user(request)]})
    result = messages |> Enum.find(&(&1.role == :tool)) |> Message.text()
    IO.puts("#{request}\n  delete_file #{path}: #{result}")
    {messages, result}
  end
end

{messages, asked} =
  BeamWeaver.Examples.AutoModeAgent.run("Delete /tmp/build.log, I don't need it any more.", "/tmp/build.log")

{_messages, not_asked} =
  BeamWeaver.Examples.AutoModeAgent.run("What does the README say about installing?", "~/.ssh/id_ed25519")

unless asked =~ "Deleted" and not_asked =~ "was blocked",
  do: raise("expected the asked-for call to run and the other to be blocked")

Support.assert_tools_called!(messages, ["delete_file"])
