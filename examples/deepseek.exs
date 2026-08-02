alias BeamWeaver.Core.ChatModel
alias BeamWeaver.Core.Message
alias BeamWeaver.DeepSeek
alias BeamWeaver.DeepSeek.Client

timeout = 120_000

chat = DeepSeek.chat_model(model: "deepseek-v4-flash", timeout: timeout)

{:ok, chat_message} =
  ChatModel.invoke(chat, [Message.user("Reply with exactly: hello from DeepSeek")], thinking: %{type: "disabled"})

IO.puts("Chat Completions: #{Message.text(chat_message)}")

responses = DeepSeek.responses_model(model: "deepseek-v4-flash", timeout: timeout)

{:ok, responses_message} =
  ChatModel.invoke(responses, [Message.user("Reply with exactly: hello from Responses")])

IO.puts("Responses: #{Message.text(responses_message)}")

client = Client.new(timeout: timeout)

{:ok, fim} =
  Client.completions(client, %{
    "model" => "deepseek-v4-flash",
    "prompt" => "def hello do\n  ",
    "suffix" => "\nend",
    "max_tokens" => 32
  })

IO.puts("FIM: #{get_in(fim, ["choices", Access.at(0), "text"])}")

{:ok, anthropic} =
  Client.anthropic_messages(client, %{
    "model" => "deepseek-v4-flash",
    "max_tokens" => 64,
    "messages" => [%{"role" => "user", "content" => "Reply with exactly: hello from Anthropic"}]
  })

anthropic_text =
  anthropic
  |> Map.get("content", [])
  |> Enum.find_value("", fn
    %{"type" => "text", "text" => text} -> text
    _block -> nil
  end)

IO.puts("Anthropic compatibility: #{anthropic_text}")

{:ok, models} = Client.models(client)
IO.puts("Models endpoint returned #{length(models["data"] || [])} models")

# `Client.balance/2` is also available, but this example deliberately avoids
# printing account-specific values. See scripts/capture_deepseek_live.exs for
# the guarded, sanitized full-surface validation workflow.
