Code.require_file("support.exs", __DIR__)

alias BeamWeaver.Agent
alias BeamWeaver.Core.Message
alias BeamWeaver.Examples.Support

system_prompt = """
You are a support analysis agent.

Use the support policy below when answering. The policy is intentionally long
and stable so repeated calls can reuse provider prompt caches.

#{String.duplicate("- Verify account ownership, preserve audit trails, cite the support rule id, and never invent data.\n", 240)}
"""

run = fn model, instructions ->
  {:ok, agent} =
    Agent.build(
      name: "prompt_caching_example",
      model: model,
      system_prompt: instructions,
      prompt_caching: [scope: "support-agent", version: "v1"]
    )

  input = %{
    messages: [Message.user("Ticket SUP-42 asks whether deleted exports can be restored. Answer in one sentence.")]
  }

  {:ok, first} = Agent.invoke(agent, input)
  {:ok, second} = Agent.invoke(agent, input)
  first_message = List.last(first.messages)
  second_message = List.last(second.messages)
  Support.assert_text!(first_message)
  IO.puts(Support.assert_text!(second_message))
  IO.puts("First cached input tokens: #{Support.cache_read_tokens(first_message)}")
  IO.puts("Second cached input tokens: #{Support.cache_read_tokens(second_message)}")

  if match?(%BeamWeaver.Google.ChatModel{}, model) do
    true = Support.cache_read_tokens(second_message) > 0
  else
    IO.puts("Cache-hit counts are observations; implicit caches do not guarantee a hit on every request.")
  end
end

case Support.model() do
  %BeamWeaver.Google.ChatModel{} = model ->
    # Gemini needs a cached-content resource for a deterministic cache check.
    # The resource contains the policy; the query adds no duplicate system prompt.
    root = "https://generativelanguage.googleapis.com/v1beta"
    headers = [{"x-goog-api-key", model.api_key}]

    cache =
      Req.post!(root <> "/cachedContents",
        headers: headers,
        json: %{
          model: "models/#{model.model}",
          ttl: "300s",
          contents: [%{role: "user", parts: [%{text: String.duplicate(system_prompt, 2)}]}]
        },
        retry: false,
        receive_timeout: 60_000
      )

    if cache.status not in 200..299, do: raise("cache creation returned HTTP #{cache.status}: #{inspect(cache.body)}")
    name = Map.fetch!(cache.body, "name")

    try do
      run.(%{model | cached_content: name}, nil)
    after
      response = Req.delete!(root <> "/" <> name, headers: headers, retry: false)
      true = response.status in 200..299
    end

  model ->
    run.(model, system_prompt)
end
