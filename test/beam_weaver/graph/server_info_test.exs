defmodule BeamWeaver.Graph.ServerInfoTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Graph.ServerInfo.User

  describe "User Access write semantics" do
    test "update_in does not pollute metadata with synthetic struct-field keys" do
      user = %User{
        identity: "abc",
        display_name: "Ada",
        is_authenticated: true,
        permissions: [:read],
        metadata: %{"role" => "admin"}
      }

      updated = update_in(user, ["role"], fn _ -> "owner" end)

      assert updated.metadata == %{"role" => "owner"}
      refute Map.has_key?(updated.metadata, "identity")
      refute Map.has_key?(updated.metadata, "display_name")
      refute Map.has_key?(updated.metadata, "is_authenticated")
      refute Map.has_key?(updated.metadata, "permissions")

      assert updated.identity == "abc"
      assert updated.display_name == "Ada"
      assert updated.is_authenticated == true
      assert updated.permissions == [:read]
    end

    test "round-tripping a synthetic key through update_in leaves metadata untouched" do
      user = %User{identity: "abc", metadata: %{"role" => "admin"}}

      updated = update_in(user, ["identity"], fn current -> current end)

      assert updated.metadata == %{"role" => "admin"}
      refute Map.has_key?(updated.metadata, "identity")
    end

    test "pop reads injected keys but only removes real metadata" do
      user = %User{identity: "abc", metadata: %{"role" => "admin"}}

      {value, popped} = pop_in(user, ["identity"])

      assert value == "abc"
      assert popped.metadata == %{"role" => "admin"}
      refute Map.has_key?(popped.metadata, "identity")
      assert popped.identity == "abc"
    end

    test "pop removes a genuine metadata key without injecting synthetic keys" do
      user = %User{identity: "abc", display_name: "Ada", metadata: %{"role" => "admin"}}

      {value, popped} = pop_in(user, ["role"])

      assert value == "admin"
      assert popped.metadata == %{}
    end
  end
end
