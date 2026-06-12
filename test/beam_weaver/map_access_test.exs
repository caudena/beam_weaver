defmodule BeamWeaver.MapAccessTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.MapAccess

  test "fetches atom and string key variants" do
    assert MapAccess.fetch(%{answer: 42}, :answer) == {:ok, 42}
    assert MapAccess.fetch(%{"answer" => 42}, :answer) == {:ok, 42}
    assert MapAccess.fetch(%{answer: 42}, "answer") == {:ok, 42}
    assert MapAccess.fetch(%{"answer" => 42}, "answer") == {:ok, 42}
    assert MapAccess.fetch(%{}, :answer) == :error
  end

  test "get preserves false and nil values" do
    assert MapAccess.get(%{enabled: false, missing: nil}, :enabled, true) == false
    assert MapAccess.get(%{"enabled" => false}, :enabled, true) == false
    assert MapAccess.get(%{missing: nil}, :missing, :default) == nil
    assert MapAccess.get(%{}, :missing, :default) == :default
  end

  test "get preserves zero and empty string values" do
    assert MapAccess.get(%{count: 0}, "count", 1) == 0
    assert MapAccess.get(%{"label" => ""}, :label, "fallback") == ""
  end

  test "has_key? treats falsey values as present" do
    assert MapAccess.has_key?(%{"enabled" => false}, :enabled)
    assert MapAccess.has_key?(%{count: 0}, "count")
  end

  test "binary lookup does not create atoms" do
    key = "beam_weaver_map_access_unknown_#{System.unique_integer([:positive])}"

    refute existing_atom?(key)
    assert MapAccess.get(%{}, key, :default) == :default
    refute existing_atom?(key)
  end

  test "normalizes only allowlisted string keys" do
    key = "beam_weaver_map_access_normalize_unknown_#{System.unique_integer([:positive])}"

    normalized = MapAccess.normalize_keys(%{"known" => 1, key => 2}, [:known])

    assert normalized.known == 1
    assert normalized[key] == 2
    refute existing_atom?(key)
  end

  defp existing_atom?(value) do
    _atom = String.to_existing_atom(value)
    true
  rescue
    ArgumentError -> false
  end
end
