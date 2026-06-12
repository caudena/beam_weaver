alias BeamWeaver.Core.ChatModel
alias BeamWeaver.Core.Message

model = %BeamWeaver.Models.FakeChatModel{response: "fake response"}

{:ok, response} = ChatModel.invoke(model, [Message.user("hello")])
IO.puts(Message.text(response))
