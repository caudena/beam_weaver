defmodule BeamWeaver.Tools.ReadFileTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent
  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Filesystem
  alias BeamWeaver.Filesystem.Local
  alias BeamWeaver.Filesystem.State
  alias BeamWeaver.Models.FakeChatModel
  alias BeamWeaver.Tools.Filesystem, as: FilesystemTools

  @moduletag :tmp_dir

  defp invoke(args, files), do: invoke_on(State.new(), args, files)

  defp invoke_on(backend, args, files \\ %{}) do
    tool = backend |> FilesystemTools.tools() |> Enum.find(&(Tool.name(&1) == "read_file"))
    Tool.invoke(tool, Map.put(args, :state, %{files: files}))
  end

  defp lines(range), do: Enum.map_join(range, "", &"line #{&1}\n")

  describe "a read that stops short of the end of the file" do
    test "ends with the lines it shows and the offset to read on from" do
      files = %{"/notes.md" => lines(1..5)}

      assert {:ok, "line 1\nline 2\n\n[Showing lines 1-2. The file continues: read again with offset 2.]"} =
               invoke(%{"file_path" => "/notes.md", "limit" => 2}, files)

      assert {:ok, "line 3\nline 4\n\n[Showing lines 3-4. The file continues: read again with offset 4.]"} =
               invoke(%{"file_path" => "/notes.md", "offset" => 2, "limit" => 2}, files)

      assert {:ok, "line 5"} = invoke(%{"file_path" => "/notes.md", "offset" => 4, "limit" => 2}, files)
    end

    test "stops at 2,000 lines by default" do
      assert {:ok, text} = invoke(%{"file_path" => "/long.md"}, %{"/long.md" => lines(1..2_001)})

      assert String.ends_with?(
               text,
               "line 2000\n\n[Showing lines 1-2000. The file continues: read again with offset 2000.]"
             )

      assert {:ok, text} = invoke(%{"file_path" => "/long.md"}, %{"/long.md" => lines(1..2_000)})
      assert text == String.trim_trailing(lines(1..2_000))
    end

    test "says the file continues when the next line is blank" do
      assert {:ok, "a\nb\n\n[Showing lines 1-2. The file continues: read again with offset 2.]"} =
               invoke(%{"file_path" => "/gap.md", "limit" => 2}, %{"/gap.md" => "a\nb\n\nc\n"})
    end

    test "has no note when the page ends with the file, on disk backends too", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "two.md"), "a\nb\n")
      File.write!(Path.join(dir, "five.md"), lines(1..5))

      for backend <- [Local.new(root: dir), Filesystem.Sandbox.new(sandbox: BeamWeaver.Sandbox.Local.new(root: dir))] do
        assert {:ok, "a\nb"} = invoke_on(backend, %{"file_path" => "/two.md", "limit" => 2})

        assert {:ok, "line 1\nline 2\n\n[Showing lines 1-2. The file continues: read again with offset 2.]"} =
                 invoke_on(backend, %{"file_path" => "/five.md", "limit" => 2})
      end
    end
  end

  describe "a read over 80,000 characters" do
    test "stops at a whole line and says the offset to read on from" do
      row = String.duplicate("x", 999)
      files = %{"/wide.csv" => String.duplicate(row <> "\n", 100)}

      assert {:ok, text} = invoke(%{"file_path" => "/wide.csv"}, files)
      assert String.length(text) <= 80_000

      assert [page, note] = String.split(text, "\n\n", parts: 2)
      rows = String.split(page, "\n")
      shown = length(rows)

      assert shown in 70..79
      assert Enum.all?(rows, &(&1 == row))

      assert note ==
               "[Showing lines 1-#{shown}: a read returns at most 80,000 characters. " <>
                 "The file continues: read again with offset #{shown}.]"

      assert {:ok, rest} = invoke(%{"file_path" => "/wide.csv", "offset" => shown}, files)
      assert rest == Enum.map_join(1..(100 - shown), "\n", fn _row -> row end)
    end

    test "cuts a longer line and says how to read on" do
      long = String.duplicate("y", 1_000_000)

      assert {:ok, text} =
               invoke(%{"file_path" => "/dump.json", "limit" => 1}, %{"/dump.json" => long <> "\nnext\n"})

      assert String.length(text) <= 80_000
      assert [cut, note] = String.split(text, "\n\n", parts: 2)
      assert String.starts_with?(long, cut)

      assert note ==
               "[Line 1 is longer than 80,000 characters and was cut: read_file can't show the rest of it, " <>
                 "but grep can search it. The file continues: read again with offset 1.]"

      assert {:ok, last} = invoke(%{"file_path" => "/dump.json"}, %{"/dump.json" => long})
      assert last =~ "[Line 1 is longer than 80,000 characters and was cut"
      refute last =~ "continues"
    end
  end

  describe "a binary file" do
    test "an image is an image block after a short notice", %{tmp_dir: dir} do
      for {name, mime_type} <- [
            {"chart.png", "image/png"},
            {"photo.jpg", "image/jpeg"},
            {"scan.JPEG", "image/jpeg"},
            {"anim.gif", "image/gif"},
            {"icon.webp", "image/webp"}
          ] do
        bytes = <<0, 159, 146, 150>> <> name
        File.write!(Path.join(dir, name), bytes)

        assert {:ok, %Message{role: :tool, content: [%ContentBlock.Text{text: notice}, image]} = message} =
                 invoke_on(Local.new(root: dir), %{"file_path" => "/" <> name})

        assert %ContentBlock.Image{mime_type: ^mime_type, data: data} = image
        assert Base.decode64!(data) == bytes
        assert notice == "File /#{name} is an image (#{byte_size(bytes)} bytes)."
        assert Message.text(message) == notice
      end
    end

    test "a PDF is a file block with its name", %{tmp_dir: dir} do
      pdf = "%PDF-1.4\n" <> <<0, 1, 2, 3, 255, 254>> <> "\n%%EOF"
      File.write!(Path.join(dir, "report.pdf"), pdf)

      assert {:ok, %Message{content: [%ContentBlock.Text{text: notice}, file]}} =
               invoke_on(Local.new(root: dir), %{"file_path" => "/report.pdf"})

      assert %ContentBlock.File{mime_type: "application/pdf", filename: "report.pdf", data: data} = file
      assert Base.decode64!(data) == pdf
      assert notice == "File /report.pdf is a PDF (#{byte_size(pdf)} bytes)."
    end

    test "another binary is a short notice, not its bytes", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "data.zip"), <<0x50, 0x4B, 0x03, 0x04, 0, 0, 0xFF, 0xFE>>)

      assert {:ok,
              "File /data.zip is binary (8 bytes) and can't be shown. " <>
                "read_file shows text files, images (PNG, JPEG, GIF, WebP) and PDFs."} =
               invoke_on(Local.new(root: dir), %{"file_path" => "/data.zip"})
    end

    test "reaches the model as an image block in the tool message", %{tmp_dir: dir} do
      photo = <<0xFF, 0xD8, 0xFF, 0xE0, 0>> <> :crypto.strong_rand_bytes(300_000)
      File.write!(Path.join(dir, "photo.jpg"), photo)

      model = %FakeChatModel{
        responses: [FakeChatModel.tool_call("read_file", %{"file_path" => "/photo.jpg"}), "A photo."],
        parent: self()
      }

      {:ok, agent} = Agent.build(model: model, filesystem: Local.new(root: dir))
      assert {:ok, _result} = Agent.invoke(agent, %{messages: ["Describe the photo"]})

      assert_received {:fake_chat_model_call, _first_call, _opts}
      assert_received {:fake_chat_model_call, messages, _opts}
      tool_message = Enum.find(messages, &(&1.role == :tool))

      assert [%ContentBlock.Text{}, %ContentBlock.Image{mime_type: "image/jpeg", data: data}] = tool_message.content
      assert Base.decode64!(data) == photo
      assert Message.text(tool_message) == "File /photo.jpg is an image (300005 bytes)."
      assert File.ls!(dir) == ["photo.jpg"]
    end
  end

  test "write_file says it creates or replaces a file" do
    tool = State.new() |> FilesystemTools.tools() |> Enum.find(&(Tool.name(&1) == "write_file"))
    assert Tool.description(tool) =~ "Create or replace a file"
    assert Tool.description(tool) =~ "edit_file"
  end
end
