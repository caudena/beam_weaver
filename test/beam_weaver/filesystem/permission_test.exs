defmodule BeamWeaver.Filesystem.PermissionTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Filesystem.FileDataUtils
  alias BeamWeaver.Filesystem.Local
  alias BeamWeaver.Filesystem.Permission
  alias BeamWeaver.Filesystem.State

  @deny_secrets [Permission.new(paths: ["/secrets/**"], mode: :deny)]

  test "rules see a path as the backends read it" do
    for path <- ["/./secrets/key.txt", "/secrets//key.txt", "//secrets/key.txt", "/secrets/", "/secrets/."] do
      refute Permission.allowed?(@deny_secrets, :read, path), path
    end

    assert Permission.allowed?(@deny_secrets, :read, "/secrets.txt")
    assert Permission.allowed?(@deny_secrets, :read, "/public/./secrets/key.txt")
  end

  test "with rules for an operation, a path the backends could read another way is denied" do
    for path <- ["secrets/key.txt", "/public/../secrets/key.txt", "/secrets\\key.txt", "~/key.txt", nil] do
      refute Permission.allowed?(@deny_secrets, :read, path), inspect(path)
      assert Permission.allowed?([], :read, path), inspect(path)
    end

    write_rules = [Permission.new(operations: [:write], paths: ["/secrets/**"], mode: :deny)]
    assert Permission.allowed?(write_rules, :read, "secrets/key.txt")
    refute Permission.allowed?(write_rules, :write, "secrets/key.txt")
  end

  test "a pattern ending in /** covers its folder and everything in it, wildcards included" do
    for {pattern, path} <- [
          {"/**/secrets/**", "/app/secrets/key.txt"},
          {"/**/secrets/**", "/secrets/key.txt"},
          {"/**/secrets/**", "/app/secrets"},
          {"/*/secrets/**", "/app/secrets/key.txt"},
          {"/*/secrets/**", "/app/secrets"},
          {"/{secrets,keys}/**", "/keys/api.txt"},
          {"/secrets/**", "/secrets"}
        ] do
      refute Permission.allowed?([Permission.new(paths: [pattern], mode: :deny)], :read, path),
             "#{pattern} should deny #{path}"
    end

    for {pattern, path} <- [
          {"/**/secrets/**", "/app/secrets2/key.txt"},
          {"/*/secrets/**", "/a/b/secrets/key.txt"},
          {"/secrets/**", "/secrets2/key.txt"}
        ] do
      assert Permission.allowed?([Permission.new(paths: [pattern], mode: :deny)], :read, path),
             "#{pattern} should not deny #{path}"
    end
  end

  test "deny rules ignore case and Unicode normalization, allow rules match exactly" do
    for path <- ["/SECRETS/key.txt", "/Secrets/Key.txt"] do
      refute Permission.allowed?(@deny_secrets, :read, path)
    end

    refute Permission.allowed?([Permission.new(paths: ["/café/**"], mode: :deny)], :read, "/café/menu.md")

    public_only = [Permission.new(paths: ["/public/**"]), Permission.new(paths: ["/**"], mode: :deny)]
    assert Permission.allowed?(public_only, :read, "/public/notes.md")
    refute Permission.allowed?(public_only, :read, "/PUBLIC/notes.md")
  end

  test "read_file refuses a denied file however the model spells its path" do
    state = %{files: %{"/secrets/key.txt" => FileDataUtils.file_data("TOPSECRET")}}
    read = file_tool(State.new(), "read_file", @deny_secrets)

    for path <- ["/secrets/key.txt", "/./secrets/key.txt", "/secrets//key.txt"] do
      assert {:ok, "Error: Permission denied reading " <> ^path} =
               Tool.invoke(read, %{"file_path" => path, "state" => state})
    end
  end

  test "read_file refuses a denied file on disk under another case" do
    root = Path.join(System.tmp_dir!(), "beam_weaver_permission_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(Path.join(root, "secrets"))
    File.write!(Path.join(root, "secrets/key.txt"), "TOPSECRET")
    read = file_tool(Local.new(root: root), "read_file", @deny_secrets)

    for path <- ["/SECRETS/key.txt", "/Secrets/./key.txt"] do
      assert {:ok, "Error: Permission denied reading " <> ^path} = Tool.invoke(read, %{"file_path" => path})
    end
  end

  defp file_tool(backend, name, permissions) do
    backend
    |> BeamWeaver.Tools.Filesystem.tools(permissions: permissions)
    |> Enum.find(&(Tool.name(&1) == name))
  end
end
