Code.require_file("support.exs", __DIR__)

alias BeamWeaver.Core.ChatModel
alias BeamWeaver.Core.Message
alias BeamWeaver.Examples.Support

{:ok, response} = ChatModel.invoke(Support.model(), [Message.user("Say hello in one short sentence.")])

IO.puts(Message.text(response))
