defmodule BeamWeaver.Tracing.OptionsTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Tracing.Options

  describe "metadata/2 custom fields" do
    test "skips list elements that are not key/value pairs" do
      metadata = Options.metadata(%{}, fields: ["not_a_pair", "another"])

      refute Map.has_key?(metadata, :custom_fields)
    end

    test "keeps valid pairs and skips non-pairs in a mixed list" do
      metadata = Options.metadata(%{}, fields: [{"region", "us"}, "stray", {"tier", "gold"}])

      assert metadata.custom_fields == %{"region" => "us", "tier" => "gold"}
    end

    test "accepts a map of custom fields" do
      metadata = Options.metadata(%{}, custom_fields: %{"region" => "us"})

      assert metadata.custom_fields == %{"region" => "us"}
    end
  end
end
