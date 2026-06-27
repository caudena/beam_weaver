alias BeamWeaver.Core.Message
alias BeamWeaver.OpenAI.ChatModel
alias BeamWeaver.OpenAI.Messages
alias BeamWeaver.OpenAI.ToolCalling

model = ChatModel.new(model: "gpt-5.4-mini")

messages = [
  Message.user("""
  Patch lib/example.ex so Example.ok?/0 returns true.
  Return the patch result.
  """)
]

tools = [ToolCalling.apply_patch()]

{:ok, request_body} = ChatModel.request_body(model, messages, tools: tools)

IO.puts("OpenAI Responses request with apply_patch:")
IO.inspect(request_body, pretty: true, limit: :infinity)

assistant_with_patch =
  Message.assistant([
    %{
      type: :apply_patch_call,
      call_id: "patch_1",
      input: """
      *** Begin Patch
      *** Update File: lib/example.ex
      @@
      -  def ok?, do: false
      +  def ok?, do: true
      *** End Patch
      """
    },
    %{
      type: :apply_patch_call_output,
      call_id: "patch_1",
      output: "Success. Updated lib/example.ex"
    },
    %{type: :text, text: "Patch applied."}
  ])

{:ok, replay_input} = Messages.to_responses_input([assistant_with_patch])

IO.puts("\nReplayable assistant history:")
IO.inspect(replay_input, pretty: true, limit: :infinity)
