defmodule BeamWeaver.Sandbox.LocalTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Sandbox

  setup do
    root =
      Path.join(System.tmp_dir!(), "beam_weaver_sandbox_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{sandbox: Sandbox.local(root: root), root: root}
  end

  test "writes, reads, executes, edits, and lists files", %{sandbox: sandbox, root: root} do
    assert BeamWeaver.Sandbox.Backend.impl_for(sandbox)

    path = Path.join(root, "nested/hello.txt")

    assert %Sandbox.WriteResult{path: ^path, error: nil} =
             Sandbox.write(sandbox, path, "Hello sandbox\nLine 2")

    assert %Sandbox.ExecuteResult{exit_code: 0, output: output, truncated: false} =
             Sandbox.execute(sandbox, "cat #{shell_quote(path)}")

    assert output == "Hello sandbox\nLine 2"

    assert %Sandbox.ReadResult{file_data: %{"content" => content, "encoding" => "utf-8"}} =
             Sandbox.read(sandbox, path)

    assert content =~ "Hello sandbox"

    assert %Sandbox.EditResult{occurrences: 1, error: nil} =
             Sandbox.edit(sandbox, path, "Line 2", "Line 3")

    assert %Sandbox.ListResult{entries: entries, error: nil} =
             Sandbox.ls(sandbox, Path.join(root, "nested"))

    assert Enum.any?(entries, &(&1["path"] == Path.join(root, "nested/hello.txt")))
  end

  test "round trips uploads and downloads in input order", %{sandbox: sandbox, root: root} do
    files = [
      {Path.join(root, "a.bin"), <<0, 1, 2, 255>>},
      {Path.join(root, "b.txt"), "text"}
    ]

    assert [
             %Sandbox.UploadResult{path: a_path, error: nil},
             %Sandbox.UploadResult{path: b_path, error: nil}
           ] = Sandbox.upload_files(sandbox, files)

    assert a_path == elem(Enum.at(files, 0), 0)
    assert b_path == elem(Enum.at(files, 1), 0)

    assert [
             %Sandbox.DownloadResult{path: ^a_path, content: <<0, 1, 2, 255>>, error: nil},
             %Sandbox.DownloadResult{path: ^b_path, content: "text", error: nil}
           ] = Sandbox.download_files(sandbox, [a_path, b_path])

    assert %Sandbox.ReadResult{file_data: %{"encoding" => "base64", "content" => encoded}} =
             Sandbox.read(sandbox, a_path)

    assert Base.decode64!(encoded) == <<0, 1, 2, 255>>
  end

  test "binary reads enforce preview limits through sync and async calls", %{
    sandbox: sandbox,
    root: root
  } do
    small_path = Path.join(root, "binary_100kib.bin")
    small_content = :binary.copy(:binary.list_to_bin(Enum.to_list(0..255)), 400)

    assert [%Sandbox.UploadResult{error: nil}] =
             Sandbox.upload_files(sandbox, [{small_path, small_content}])

    assert %Sandbox.ReadResult{
             file_data: %{"encoding" => "base64", "content" => encoded},
             error: nil
           } =
             Sandbox.read(sandbox, small_path)

    assert Base.decode64!(encoded) == small_content

    large_path = Path.join(root, "binary_1mib.bin")
    large_content = :binary.copy(:binary.list_to_bin(Enum.to_list(0..255)), 4_096)

    assert [%Sandbox.UploadResult{error: nil}] =
             sandbox
             |> Sandbox.async_upload_files([{large_path, large_content}])
             |> Task.await()

    assert %Sandbox.ReadResult{file_data: nil, error: error} =
             sandbox
             |> Sandbox.async_read(large_path)
             |> Task.await()

    assert error ==
             "File '#{large_path}': Binary file exceeds maximum preview size of 512000 bytes"
  end

  test "glob returns relative matches and grep returns absolute plus relative paths", %{
    sandbox: sandbox,
    root: root
  } do
    Sandbox.upload_files(sandbox, [
      {Path.join(root, "src/a.ex"), "defmodule A do\n  def hello, do: :ok\nend\n"},
      {Path.join(root, "src/b.txt"), "nothing\n"}
    ])

    assert %Sandbox.GlobResult{matches: [%{"path" => "a.ex", "is_dir" => false}]} =
             Sandbox.glob(sandbox, "*.ex", path: Path.join(root, "src"))

    expected_path = Path.join(root, "src/a.ex")

    assert %Sandbox.GrepResult{
             matches: [
               %{
                 "path" => ^expected_path,
                 "relative_path" => "a.ex",
                 "line" => 2,
                 "text" => "  def hello, do: :ok"
               }
             ]
           } =
             Sandbox.grep(sandbox, "def hello", path: Path.join(root, "src"))
  end

  test "text reads paginate by lines and handle EOF boundaries", %{sandbox: sandbox, root: root} do
    path = Path.join(root, "lines.txt")
    content = Enum.map_join(1..10, "\n", &"Row_#{&1}_content")

    assert %Sandbox.WriteResult{error: nil} = Sandbox.write(sandbox, path, content)

    assert %Sandbox.ReadResult{file_data: %{"content" => "Row_6_content\nRow_7_content"}} =
             Sandbox.read(sandbox, path, offset: 5, limit: 2)

    assert %Sandbox.ReadResult{file_data: %{"content" => ""}} =
             Sandbox.read(sandbox, path, offset: 10, limit: 5)

    assert %Sandbox.ReadResult{file_data: %{"content" => ""}} =
             Sandbox.read(sandbox, path, offset: 0, limit: 0)
  end

  test "glob marks directories and supports hidden and character-class patterns", %{
    sandbox: sandbox,
    root: root
  } do
    base = Path.join(root, "glob")

    Sandbox.upload_files(sandbox, [
      {Path.join(base, "file1.txt"), "content"},
      {Path.join(base, "file2.txt"), "content"},
      {Path.join(base, "fileA.txt"), "content"},
      {Path.join(base, ".hidden"), "content"},
      {Path.join(base, "dir/child.txt"), "content"}
    ])

    assert %Sandbox.GlobResult{matches: matches} = Sandbox.glob(sandbox, "*", path: base)
    assert %{"path" => "dir", "is_dir" => true} in matches
    assert %{"path" => "file1.txt", "is_dir" => false} in matches

    assert %Sandbox.GlobResult{matches: [%{"path" => ".hidden", "is_dir" => false}]} =
             Sandbox.glob(sandbox, ".*", path: base)

    assert %Sandbox.GlobResult{matches: char_matches} =
             Sandbox.glob(sandbox, "file[1-2].txt", path: base)

    assert Enum.map(char_matches, & &1["path"]) == ["file1.txt", "file2.txt"]
  end

  test "grep recurses with glob filters and reports stable line numbers", %{
    sandbox: sandbox,
    root: root
  } do
    base = Path.join(root, "grep")
    target = Path.join(base, "a/b/target.py")

    Sandbox.upload_files(sandbox, [
      {target, "Line 1\nneedle\nLine 3"},
      {Path.join(base, "ignore.txt"), "needle"}
    ])

    assert %Sandbox.GrepResult{
             matches: [%{"path" => ^target, "relative_path" => "a/b/target.py", "line" => 2}]
           } =
             Sandbox.grep(sandbox, "needle", path: base, glob: "*.py")
  end

  test "edit handles multiple matches, literals, multiline content, and missing files", %{
    sandbox: sandbox,
    root: root
  } do
    multi = Path.join(root, "multi.txt")

    assert %Sandbox.WriteResult{error: nil} =
             Sandbox.write(sandbox, multi, "apple\nbanana\napple")

    assert %Sandbox.EditResult{error: "multiple occurrences", occurrences: 2} =
             Sandbox.edit(sandbox, multi, "apple", "pear")

    assert %Sandbox.EditResult{error: nil, occurrences: 2} =
             Sandbox.edit(sandbox, multi, "apple", "pear", replace_all: true)

    assert %Sandbox.ReadResult{file_data: %{"content" => "pear\nbanana\npear"}} =
             Sandbox.read(sandbox, multi)

    special = Path.join(root, "special.txt")

    assert %Sandbox.WriteResult{error: nil} =
             Sandbox.write(sandbox, special, "Price: $100\nLine 1\nLine 2")

    assert %Sandbox.EditResult{error: nil, occurrences: 1} =
             Sandbox.edit(sandbox, special, "$100", "$200")

    assert %Sandbox.EditResult{error: nil, occurrences: 1} =
             Sandbox.edit(sandbox, special, "Line 1\nLine 2", "Combined")

    assert %Sandbox.EditResult{error: "string not found"} =
             Sandbox.edit(sandbox, special, "missing", "value")

    assert %Sandbox.EditResult{error: "file_not_found"} =
             Sandbox.edit(sandbox, Path.join(root, "missing.txt"), "old", "new")
  end

  test "download and path validation return tagged error strings", %{sandbox: sandbox, root: root} do
    dir = Path.join(root, "download_dir")
    path = Path.join(root, "no_read.txt")

    assert %Sandbox.ExecuteResult{exit_code: 0} =
             Sandbox.execute(sandbox, "mkdir -p #{shell_quote(dir)}")

    assert [%Sandbox.DownloadResult{path: ^dir, content: nil, error: "is_directory"}] =
             Sandbox.download_files(sandbox, [dir])

    assert %Sandbox.WriteResult{error: nil} = Sandbox.write(sandbox, path, "secret")

    assert %Sandbox.ExecuteResult{exit_code: 0} =
             Sandbox.execute(sandbox, "chmod 000 #{shell_quote(path)}")

    try do
      assert [%Sandbox.DownloadResult{path: ^path, content: nil, error: "permission_denied"}] =
               Sandbox.download_files(sandbox, [path])
    after
      Sandbox.execute(sandbox, "chmod 644 #{shell_quote(path)} || true")
    end

    malicious_path = "'; echo INJECTED; #"

    assert %Sandbox.ListResult{entries: nil, error: "invalid_path"} =
             Sandbox.ls(sandbox, malicious_path)

    assert %Sandbox.ReadResult{file_data: nil, error: "invalid_path"} =
             Sandbox.read(sandbox, malicious_path)

    assert [%Sandbox.UploadResult{path: "relative.txt", error: "invalid_path"}] =
             Sandbox.upload_files(sandbox, [{"relative.txt", "nope"}])
  end

  test "large payloads and async helpers preserve full contents", %{sandbox: sandbox, root: root} do
    path = Path.join(root, "large.txt")
    content = 1..2_500 |> Enum.map_join("\n", &"#{&1}:0123456789abcdef")

    assert %Sandbox.WriteResult{error: nil} =
             sandbox
             |> Sandbox.async_write(path, content)
             |> Task.await()

    assert %Sandbox.ReadResult{file_data: %{"content" => page}} =
             sandbox
             |> Sandbox.async_read(path, offset: 100, limit: 2)
             |> Task.await()

    assert page == "101:0123456789abcdef\n102:0123456789abcdef"

    assert [%Sandbox.DownloadResult{path: ^path, content: ^content, error: nil}] =
             sandbox
             |> Sandbox.async_download_files([path])
             |> Task.await()

    assert %Sandbox.ExecuteResult{exit_code: 0, output: output, truncated: false} =
             sandbox
             |> Sandbox.async_execute("python3 -c \"import sys; sys.stdout.write('x' * (500 * 1024))\"")
             |> Task.await()

    assert byte_size(output) == 500 * 1024
  end

  test "large upload and download preserve bytes and report expected size", %{
    sandbox: sandbox,
    root: root
  } do
    path = Path.join(root, "large_upload.bin")
    content = :binary.copy("0123456789abcdef", 640 * 1024)

    assert byte_size(content) == 10 * 1024 * 1024

    assert [%Sandbox.UploadResult{path: ^path, error: nil}] =
             Sandbox.upload_files(sandbox, [{path, content}])

    assert %Sandbox.ExecuteResult{exit_code: 0, output: output} =
             Sandbox.execute(sandbox, "wc -c #{shell_quote(path)}")

    assert output =~ Integer.to_string(byte_size(content))

    assert [%Sandbox.DownloadResult{path: ^path, content: ^content, error: nil}] =
             Sandbox.download_files(sandbox, [path])
  end

  test "invalid paths and preview limits return standard error markers", %{
    sandbox: sandbox,
    root: root
  } do
    assert [%Sandbox.DownloadResult{path: "relative.txt", content: nil, error: "invalid_path"}] =
             Sandbox.download_files(sandbox, ["relative.txt"])

    path = Path.join(root, "large.bin")
    Sandbox.upload_files(sandbox, [{path, :binary.copy(<<0>>, 513_000)}])

    assert %Sandbox.ReadResult{file_data: nil, error: error} = Sandbox.read(sandbox, path)
    assert error =~ "Binary file exceeds maximum preview size"
  end

  test "async helpers are Task-backed facade calls", %{sandbox: sandbox, root: root} do
    path = Path.join(root, "async.txt")

    assert %Sandbox.WriteResult{error: nil} =
             sandbox
             |> Sandbox.async_write(path, "async")
             |> Task.await()

    assert %Sandbox.ReadResult{file_data: %{"content" => "async"}} =
             sandbox
             |> Sandbox.async_read(path)
             |> Task.await()
  end

  defp shell_quote(path), do: "'" <> String.replace(path, "'", "'\\''") <> "'"
end
