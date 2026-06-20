defmodule BeamWeaver.OpenAI.ProviderTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.OpenAI.Provider

  describe "infer_provider?/2" do
    test "matches OpenAI gpt and o-series chat models" do
      assert Provider.infer_provider?("gpt-5.5", :chat)
      assert Provider.infer_provider?("o1", :chat)
      assert Provider.infer_provider?("o1-mini", :chat)
      assert Provider.infer_provider?("o3", :chat)
      assert Provider.infer_provider?("o4-mini", :chat)
      assert Provider.infer_provider?("chatgpt-4o-latest", :chat)
    end

    test "does not misroute non-OpenAI models that merely begin with o" do
      refute Provider.infer_provider?("ollama-llama3", :chat)
      refute Provider.infer_provider?("open-mistral-7b", :chat)
      refute Provider.infer_provider?("openchat", :chat)
    end

    test "matches OpenAI embedding models" do
      assert Provider.infer_provider?("text-embedding-3-small", :embedding)
      refute Provider.infer_provider?("text-embedding-3-small", :chat)
    end

    test "returns false for unrelated models" do
      refute Provider.infer_provider?("claude-3-5-sonnet", :chat)
      refute Provider.infer_provider?("gemini-1.5-pro", :chat)
    end
  end
end
