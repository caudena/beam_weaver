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

  test "writes, reads, executes, edits, and lists files", %{sandbox: sandbox} do
    assert BeamWeaver.Sandbox.sandbox?(sandbox)

    path = "/nested/hello.txt"

    assert %Sandbox.WriteResult{path: ^path, error: nil} =
             Sandbox.write(sandbox, path, "Hello sandbox\nLine 2")

    # `execute` runs on the host with the sandbox root as its cwd, so it uses
    # the file's path relative to the root, not the sandbox-absolute path.
    assert %Sandbox.ExecuteResult{exit_code: 0, output: output, truncated: false} =
             Sandbox.execute(sandbox, "cat nested/hello.txt")

    assert output == "Hello sandbox\nLine 2"

    assert %Sandbox.ReadResult{file_data: %{"content" => content, "encoding" => "utf-8"}} =
             Sandbox.read(sandbox, path)

    assert content =~ "Hello sandbox"

    assert %Sandbox.EditResult{occurrences: 1, error: nil} =
             Sandbox.edit(sandbox, path, "Line 2", "Line 3")

    assert %Sandbox.ListResult{entries: entries, error: nil} = Sandbox.ls(sandbox, "/nested")

    assert Enum.any?(entries, &(&1["path"] == "/nested/hello.txt"))
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

  test "binary reads enforce the preview size limit", %{sandbox: sandbox, root: root} do
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
             Sandbox.upload_files(sandbox, [{large_path, large_content}])

    assert %Sandbox.ReadResult{file_data: nil, error: error} = Sandbox.read(sandbox, large_path)

    assert error ==
             "File '#{large_path}': Binary file exceeds maximum preview size of 512000 bytes"
  end

  test "glob returns relative matches and grep returns sandbox plus relative paths", %{
    sandbox: sandbox
  } do
    Sandbox.upload_files(sandbox, [
      {"/src/a.ex", "defmodule A do\n  def hello, do: :ok\nend\n"},
      {"/src/b.txt", "nothing\n"}
    ])

    assert %Sandbox.GlobResult{matches: [%{"path" => "/src/a.ex", "is_dir" => false}]} =
             Sandbox.glob(sandbox, "*.ex", path: "/src")

    assert %Sandbox.GrepResult{
             matches: [
               %{
                 "path" => "/src/a.ex",
                 "relative_path" => "a.ex",
                 "line" => 2,
                 "text" => "  def hello, do: :ok"
               }
             ]
           } =
             Sandbox.grep(sandbox, "def hello", path: "/src")
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

  test "grep recurses with glob filters and reports stable line numbers", %{sandbox: sandbox} do
    base = "/grep"
    target = "/grep/a/b/target.py"

    Sandbox.upload_files(sandbox, [
      {target, "Line 1\nneedle\nLine 3"},
      {"/grep/ignore.txt", "needle"}
    ])

    assert %Sandbox.GrepResult{
             matches: [%{"path" => ^target, "relative_path" => "a/b/target.py", "line" => 2}]
           } =
             Sandbox.grep(sandbox, "needle", path: base, glob: "*.py")
  end

  test "binary reads return the whole file, whatever the line window", %{sandbox: sandbox, root: root} do
    path = Path.join(root, "image.bin")
    content = :binary.copy(<<0, 1, 2, 255>>, 1_000)
    assert [%Sandbox.UploadResult{error: nil}] = Sandbox.upload_files(sandbox, [{path, content}])

    assert %Sandbox.ReadResult{file_data: %{"encoding" => "base64", "content" => encoded}} =
             Sandbox.read(sandbox, path, offset: 0, limit: 2_000)

    assert Base.decode64!(encoded) == content
  end

  test "reading or editing a directory reports is_directory", %{sandbox: sandbox} do
    assert %Sandbox.ExecuteResult{exit_code: 0} = Sandbox.execute(sandbox, "mkdir -p a_dir")
    assert %Sandbox.ReadResult{error: "is_directory"} = Sandbox.read(sandbox, "/a_dir")
    assert %Sandbox.EditResult{error: "is_directory"} = Sandbox.edit(sandbox, "/a_dir", "a", "b")
  end

  test "an empty old string is not found, even in an empty file", %{sandbox: sandbox} do
    assert %Sandbox.WriteResult{error: nil} = Sandbox.write(sandbox, "/empty.txt", "")
    assert %Sandbox.EditResult{error: "string not found"} = Sandbox.edit(sandbox, "/empty.txt", "", "text")
    assert {:ok, ""} = File.read(Path.join(sandbox.root, "empty.txt"))
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

  test "download and path validation return tagged error strings", %{sandbox: sandbox} do
    dir = "/download_dir"
    path = "/no_read.txt"

    assert %Sandbox.ExecuteResult{exit_code: 0} = Sandbox.execute(sandbox, "mkdir -p download_dir")

    assert [%Sandbox.DownloadResult{path: ^dir, content: nil, error: "is_directory"}] =
             Sandbox.download_files(sandbox, [dir])

    assert %Sandbox.WriteResult{error: nil} = Sandbox.write(sandbox, path, "secret")

    assert %Sandbox.ExecuteResult{exit_code: 0} = Sandbox.execute(sandbox, "chmod 000 no_read.txt")

    try do
      assert [%Sandbox.DownloadResult{path: ^path, content: nil, error: "permission_denied"}] =
               Sandbox.download_files(sandbox, [path])
    after
      Sandbox.execute(sandbox, "chmod 644 no_read.txt || true")
    end

    malicious_path = "'; echo INJECTED; #"

    assert %Sandbox.ListResult{entries: nil, error: "invalid_path"} =
             Sandbox.ls(sandbox, malicious_path)

    assert %Sandbox.ReadResult{file_data: nil, error: "invalid_path"} =
             Sandbox.read(sandbox, malicious_path)

    assert [%Sandbox.UploadResult{path: "relative.txt", error: "invalid_path"}] =
             Sandbox.upload_files(sandbox, [{"relative.txt", "nope"}])
  end

  test "blocks symlink escapes for reads, writes, listings, and recursive grep", %{
    sandbox: sandbox,
    root: root
  } do
    outside =
      Path.join(System.tmp_dir!(), "beam_weaver_sandbox_escape_#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf(outside) end)

    secret = Path.join(outside, "secret.txt")
    File.write!(secret, "needle outside-secret")

    assert :ok = File.ln_s(secret, Path.join(root, "escape"))
    assert :ok = File.ln_s(outside, Path.join(root, "outdir"))

    assert %Sandbox.ReadResult{file_data: nil, error: "invalid_path"} =
             Sandbox.read(sandbox, "/escape")

    # A host path is taken literally as a sandbox path (`/<root>/escape`), which
    # resolves under the root and does not exist, rather than reaching the
    # symlink at `<root>/escape`.
    assert %Sandbox.ReadResult{file_data: nil, error: "file_not_found"} =
             Sandbox.read(sandbox, Path.join(root, "escape"))

    assert %Sandbox.WriteResult{path: "/outdir/owned.txt", error: "invalid_path"} =
             Sandbox.write(sandbox, "/outdir/owned.txt", "owned")

    refute File.exists?(Path.join(outside, "owned.txt"))

    assert %Sandbox.ListResult{entries: entries} = Sandbox.ls(sandbox, "/")
    refute Enum.any?(entries, &(&1["path"] in ["/escape", "/outdir"]))

    assert %Sandbox.GlobResult{matches: matches} = Sandbox.glob(sandbox, "*", path: "/")
    refute Enum.any?(matches, &(&1["path"] in ["escape", "outdir"]))

    assert %Sandbox.GrepResult{matches: []} = Sandbox.grep(sandbox, "outside-secret", path: "/")
  end

  test "a `..` after a symlink can't climb out of the root", %{sandbox: sandbox, root: root} do
    outside = Path.join(Path.dirname(root), "#{Path.basename(root)}_outside.txt")
    File.write!(outside, "needle outside-secret")
    on_exit(fn -> File.rm(outside) end)

    # /x/up is the root, so `../x/up/../<name>` from /notes is the file next
    # to the root. Read as text it is /x/<name>, a decoy inside the root.
    File.mkdir_p!(Path.join(root, "x"))
    File.mkdir_p!(Path.join(root, "notes"))
    File.ln_s!("..", Path.join(root, "x/up"))
    File.write!(Path.join([root, "x", Path.basename(outside)]), "decoy")
    File.ln_s!("../x/up/../#{Path.basename(outside)}", Path.join(root, "notes/escape"))

    assert %Sandbox.ReadResult{file_data: nil, error: "invalid_path"} = Sandbox.read(sandbox, "/notes/escape")
    assert [%Sandbox.DownloadResult{error: "invalid_path"}] = Sandbox.download_files(sandbox, ["/notes/escape"])
    assert %Sandbox.GrepResult{matches: []} = Sandbox.grep(sandbox, "outside-secret", path: "/")
    assert %Sandbox.ListResult{entries: []} = Sandbox.ls(sandbox, "/notes")
    assert Sandbox.canonical_paths(sandbox, ["/notes/escape"]) == [{:error, "invalid_path"}]

    assert %Sandbox.EditResult{error: "invalid_path"} = Sandbox.edit(sandbox, "/notes/escape", "needle", "changed")

    assert [%Sandbox.UploadResult{error: "invalid_path"}] =
             Sandbox.upload_files(sandbox, [{"/notes/escape", "changed"}])

    assert File.read!(outside) == "needle outside-secret"
  end

  test "large payloads preserve full contents", %{sandbox: sandbox, root: root} do
    path = Path.join(root, "large.txt")
    content = 1..2_500 |> Enum.map_join("\n", &"#{&1}:0123456789abcdef")

    assert %Sandbox.WriteResult{error: nil} = Sandbox.write(sandbox, path, content)

    assert %Sandbox.ReadResult{file_data: %{"content" => page}} =
             Sandbox.read(sandbox, path, offset: 100, limit: 2)

    assert page == "101:0123456789abcdef\n102:0123456789abcdef"

    assert [%Sandbox.DownloadResult{path: ^path, content: ^content, error: nil}] =
             Sandbox.download_files(sandbox, [path])

    assert %Sandbox.ExecuteResult{exit_code: 0, output: output, truncated: false} =
             Sandbox.execute(sandbox, "python3 -c \"import sys; sys.stdout.write('x' * (500 * 1024))\"")

    assert byte_size(output) == 500 * 1024
  end

  test "execute caps command output while preserving exit status", %{root: root} do
    sandbox = Sandbox.local(root: root, max_output_bytes: 1_024)

    assert %Sandbox.ExecuteResult{exit_code: 0, output: output, truncated: true} =
             Sandbox.execute(sandbox, "python3 -c \"import sys; sys.stdout.write('x' * 2048)\"")

    assert byte_size(output) == 1_024
    assert output == :binary.copy("x", 1_024)
  end

  test "large upload and download preserve bytes and report expected size", %{sandbox: sandbox} do
    path = "/large_upload.bin"
    content = :binary.copy("0123456789abcdef", 640 * 1024)

    assert byte_size(content) == 10 * 1024 * 1024

    assert [%Sandbox.UploadResult{path: ^path, error: nil}] =
             Sandbox.upload_files(sandbox, [{path, content}])

    assert %Sandbox.ExecuteResult{exit_code: 0, output: output} =
             Sandbox.execute(sandbox, "wc -c large_upload.bin")

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

  test "a host path is taken literally as a sandbox path, not reinterpreted", %{
    sandbox: sandbox,
    root: root
  } do
    File.mkdir_p!(Path.join(root, "secrets"))
    File.write!(Path.join([root, "secrets", "key.txt"]), "TOP-SECRET")

    # The sandbox path reads the file (it is in the sandbox).
    assert %Sandbox.ReadResult{file_data: %{"content" => "TOP-SECRET"}} =
             Sandbox.read(sandbox, "/secrets/key.txt")

    # A full host path pointing inside the root is treated as the sandbox path
    # `/<root>/secrets/key.txt`, which resolves under the root and does not
    # exist, so it can't reach `/secrets/key.txt` behind a permission rule.
    host_path = Path.join([root, "secrets", "key.txt"])

    assert %Sandbox.ReadResult{file_data: nil, error: "file_not_found"} =
             Sandbox.read(sandbox, host_path)
  end

  test "glob and grep return an error for a malformed pattern", %{sandbox: sandbox} do
    assert %Sandbox.GlobResult{matches: nil, error: "invalid_pattern"} =
             Sandbox.glob(sandbox, "{a")

    assert %Sandbox.GrepResult{matches: nil, error: "invalid_pattern"} =
             Sandbox.grep(sandbox, "needle", glob: "{a")
  end
end
