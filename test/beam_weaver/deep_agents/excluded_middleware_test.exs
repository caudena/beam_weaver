defmodule BeamWeaver.Agent.Middleware.ExclusionTest.PublicOne do
  defstruct []
  def name(_middleware), do: "public_one"
end

defmodule BeamWeaver.Agent.Middleware.ExclusionTest.PublicTwo do
  defstruct []
  def name(_middleware), do: "public_two"
end

defmodule BeamWeaver.Agent.Middleware.ExclusionTest.CollisionOne do
  defstruct []
  def name(_middleware), do: "collision"
end

defmodule BeamWeaver.Agent.Middleware.ExclusionTest.CollisionTwo do
  defstruct []
  def name(_middleware), do: "collision"
end

defmodule BeamWeaver.Agent.Middleware.ExclusionTest.Required do
  defstruct []
  def name(_middleware), do: "required"
end

defmodule BeamWeaver.Agent.Middleware.ExclusionTest do
  use ExUnit.Case, async: true

  # Upstream reference:
  # - libs/deepagents/deepagents/_excluded_middleware.py

  alias __MODULE__.CollisionOne
  alias __MODULE__.CollisionTwo
  alias __MODULE__.PublicOne
  alias __MODULE__.PublicTwo
  alias __MODULE__.Required
  alias BeamWeaver.Agent.CapabilityProfile
  alias BeamWeaver.Agent.Middleware.Exclusion

  test "validates required scaffolding class and name exclusions" do
    class_profile = CapabilityProfile.new(excluded_middleware: [Required])
    name_profile = CapabilityProfile.new(excluded_middleware: ["required"])

    assert_raise ArgumentError, ~r/required scaffolding.*Required/, fn ->
      Exclusion.validate_config(class_profile, required_classes: [Required])
    end

    assert_raise ArgumentError, ~r/required scaffolding.*required/, fn ->
      Exclusion.validate_config(name_profile, required_names: ["required"])
    end
  end

  test "applies class and string exclusions while preserving kept order" do
    one = %PublicOne{}
    two = %PublicTwo{}
    required = %Required{}

    profile = CapabilityProfile.new(excluded_middleware: [PublicOne, "public_two"])

    assert {[^required], matches} =
             Exclusion.apply_excluded_middleware([one, two, required], profile)

    assert MapSet.member?(matches.matched_classes, PublicOne)
    assert MapSet.member?(matches.matched_names, "public_two")
  end

  test "name exclusions raise when they match multiple concrete classes" do
    profile = CapabilityProfile.new(excluded_middleware: ["collision"])

    assert_raise ArgumentError, ~r/matched multiple distinct middleware classes/, fn ->
      Exclusion.apply_excluded_middleware(
        [%CollisionOne{}, %CollisionTwo{}],
        profile
      )
    end
  end

  test "coverage auditing fails for stale exclusions and accepts merged matches" do
    profile = CapabilityProfile.new(excluded_middleware: [PublicOne, "public_two"])

    assert_raise ArgumentError, ~r/matched no middleware.*PublicOne.*public_two/, fn ->
      Exclusion.verify_coverage(profile, %{
        matched_classes: MapSet.new(),
        matched_names: MapSet.new()
      })
    end

    {_filtered, first} =
      Exclusion.apply_excluded_middleware([%PublicOne{}], profile)

    {_filtered, second} =
      Exclusion.apply_excluded_middleware([%PublicTwo{}], profile)

    assert :ok =
             profile
             |> Exclusion.verify_coverage(Exclusion.merge_matches(first, second))
  end
end
