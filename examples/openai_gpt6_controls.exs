# Live: mix run examples/openai_gpt6_controls.exs
# Uses OPENAI_API_KEY from config/runtime.exs.

alias BeamWeaver.Config
alias BeamWeaver.Core.ChatModel
alias BeamWeaver.Core.Message
alias BeamWeaver.OpenAI.ChatModel, as: OpenAIModel

key = Config.get([:openai, :api_key])
if key in [nil, ""], do: raise("configure OPENAI_API_KEY before running this example")

model = OpenAIModel.new(model: "gpt-6-luna", api_key: key, timeout: 60_000)

{:ok, response} =
  ChatModel.invoke(model, [Message.user("Reply with exactly OK.")],
    access_programs: %{cyber: :standard},
    max_tokens: 64
  )

"OK" = response |> Message.text() |> String.trim()
%{"cyber" => "standard"} = response.response_metadata.access_programs

{:ok, prewarm} =
  ChatModel.invoke(model, [Message.user(String.duplicate("Cache this short reference sentence. ", 80))],
    prompt_cache_options: %{mode: :implicit, ttl: "30m", prewarm: true},
    max_tokens: 16
  )

"" = Message.text(prewarm)
IO.puts("GPT-6 Luna access-program and cache-prewarm requests passed.")
