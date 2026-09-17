defmodule BeamWeaver.PromptCacheTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.PromptCache

  @model "openai:gpt-5.6-terra"

  test "a short scope keeps the readable key" do
    key = PromptCache.key("deal_analysis", @model, "system prompt", version: "v2")

    assert String.starts_with?(key, "bwpc:v2:deal_analysis:openai-gpt-5.6-terra:")
    assert byte_size(key) <= PromptCache.max_key_bytes()
  end

  test "a long scope collapses into a hash that fits the provider limit" do
    key = PromptCache.key("deal_company_resolver_agent", @model, "system prompt", version: "v2")

    assert byte_size(key) <= PromptCache.max_key_bytes()
    assert String.starts_with?(key, "bwpc:v2:h:")
    # the whole url-safe base64 SHA-256 fits, so nothing of the hash is dropped
    assert byte_size(key) == byte_size("bwpc:v2:h:") + 43
    assert key == PromptCache.key("deal_company_resolver_agent", @model, "system prompt", version: "v2")
  end

  test "collapsed keys still differ by scope, model and prompt" do
    base = PromptCache.key("deal_company_resolver_agent", @model, "system prompt", version: "v2")

    assert base != PromptCache.key("deal_company_resolver_agent_2", @model, "system prompt", version: "v2")
    assert base != PromptCache.key("deal_company_resolver_agent", "openai:gpt-5.6-luna", "system prompt", version: "v2")
    assert base != PromptCache.key("deal_company_resolver_agent", @model, "other prompt", version: "v2")
  end

  test "no scope, model or version makes the key exceed the limit" do
    long = String.duplicate("a", 200)

    for scope <- ["s", long], model <- ["m", long], version <- ["v1", long] do
      assert byte_size(PromptCache.key(scope, model, "p", version: version)) <= PromptCache.max_key_bytes()
    end
  end
end
