# Live: mix run examples/anthropic_opus55_compaction.exs
# Uses ANTHROPIC_API_KEY from config/runtime.exs.

alias BeamWeaver.Anthropic.ChatModel, as: AnthropicModel
alias BeamWeaver.Config
alias BeamWeaver.Core.ChatModel
alias BeamWeaver.Core.Message

key = Config.get([:anthropic, :api_key])
if key in [nil, ""], do: raise("configure ANTHROPIC_API_KEY before running this example")

model =
  AnthropicModel.new(
    model: "claude-opus-5-5",
    api_key: key,
    timeout: 120_000,
    include_response_headers: true
  )

history = [Message.user("The code word is BLUE. Remember it."), Message.assistant("I will remember BLUE.")]

{:ok, summary} =
  ChatModel.invoke(model, history,
    compaction: %{type: :summarize, instructions: "Preserve the code word exactly."},
    max_tokens: 4096
  )

"compaction" = summary.status
[%{"signature" => signature}] = summary.response_metadata.raw_provider_response["content"]
true = is_binary(signature) and signature != ""

workspace_id = get_in(summary.response_metadata, [:headers, :anthropic_workspace_id])
true = is_binary(workspace_id)

{:ok, reply} =
  ChatModel.invoke(model, [summary, Message.user("What is the code word? Reply with one word.")],
    workspace_id: workspace_id
  )

true = String.contains?(String.upcase(Message.text(reply)), "BLUE")

definition = %{
  type: :tool_addition,
  tool: %{
    type: :tool_definition,
    definition: %{
      type: :custom,
      name: "lookup",
      description: "Returns the code word for a query.",
      input_schema: %{"type" => "object", "properties" => %{"query" => %{"type" => "string"}}}
    }
  }
}

{:ok, tool_reply} =
  ChatModel.invoke(model, [Message.user("Call lookup with query code word."), Message.system([definition])],
    max_tokens: 512
  )

"tool_use" = tool_reply.status
IO.puts("Claude Opus 5.5 signed compaction, replay, and inline tool requests passed.")
