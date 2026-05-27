defmodule BeamWeaver.Filesystem.FileDataUtils do
  @moduledoc false

  alias BeamWeaver.Filesystem
  alias BeamWeaver.Filesystem.FileData

  @binary_preview_bytes 512_000
  @empty_content_warning "System reminder: File exists but has empty contents"

  def binary_preview_bytes, do: @binary_preview_bytes
  def empty_content_warning, do: @empty_content_warning

  def file_data(content, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &now/0)

    %FileData{
      content: content,
      encoding: Keyword.get(opts, :encoding, "utf-8"),
      created_at: Keyword.get(opts, :created_at, now),
      modified_at: Keyword.get(opts, :modified_at, now)
    }
  end

  def create_file_data(content, opts \\ []), do: file_data(content, opts)

  def update_file_data(%FileData{} = data, content) do
    %{data | content: content, modified_at: now()}
  end

  def update_file_data(data, content) when is_map(data) do
    data
    |> normalize_file_data()
    |> update_file_data(content)
  end

  def file_data_to_string(%FileData{content: content}), do: content || ""

  def file_data_to_string(%{"content" => content}) when is_list(content),
    do: Enum.join(content, "\n")

  def file_data_to_string(%{"content" => content}), do: content || ""
  def file_data_to_string(%{content: content}) when is_list(content), do: Enum.join(content, "\n")
  def file_data_to_string(%{content: content}), do: content || ""
  def file_data_to_string(content) when is_binary(content), do: content
  def file_data_to_string(_content), do: ""

  def check_empty_content(content) when is_binary(content) do
    if String.trim(content) == "", do: @empty_content_warning
  end

  def check_empty_content(_content), do: @empty_content_warning

  def file_data_from_upload(content, opts \\ []) do
    bytes = IO.iodata_to_binary(content)

    if binary_content?(bytes) do
      file_data(Base.encode64(bytes), Keyword.put(opts, :encoding, "base64"))
    else
      file_data(bytes, Keyword.put(opts, :encoding, "utf-8"))
    end
  end

  def normalize_file_data(%FileData{} = data), do: data

  def normalize_file_data(%{"content" => content} = data) do
    %FileData{
      content: content,
      encoding: Map.get(data, "encoding", "utf-8"),
      created_at: Map.get(data, "created_at"),
      modified_at: Map.get(data, "modified_at")
    }
  end

  def normalize_file_data(%{content: content} = data) do
    %FileData{
      content: content,
      encoding: Map.get(data, :encoding, "utf-8"),
      created_at: Map.get(data, :created_at),
      modified_at: Map.get(data, :modified_at)
    }
  end

  def normalize_file_data(lines) when is_list(lines),
    do: file_data(Enum.join(lines, "\n"), encoding: "utf-8")

  def normalize_file_data(content) when is_binary(content),
    do: file_data(content, encoding: "utf-8")

  def normalize_file_data(_other), do: nil

  def read_content(%FileData{content: content, encoding: "utf-8"}, opts) do
    content
    |> slice_lines(opts)
    |> maybe_slice_lines()
  end

  def read_content(%FileData{content: content, encoding: "base64"}, _opts),
    do: {:ok, content || ""}

  def read_content(_data, _opts), do: {:error, "invalid_file_data"}

  def encode_disk_file(path, virtual_path, opts \\ []) do
    max_binary_preview = Keyword.get(opts, :max_binary_preview, @binary_preview_bytes)

    with {:ok, bytes} <- File.read(path) do
      cond do
        bytes == "" ->
          {:ok, file_data(@empty_content_warning)}

        binary_content?(bytes) and byte_size(bytes) > max_binary_preview ->
          {:error, "File '#{virtual_path}': Binary file exceeds maximum preview size of #{max_binary_preview} bytes"}

        binary_content?(bytes) ->
          {:ok, file_data(Base.encode64(bytes), encoding: "base64")}

        true ->
          bytes
          |> slice_lines(opts)
          |> maybe_slice_lines()
          |> case do
            {:ok, content} -> {:ok, file_data(content, encoding: "utf-8")}
            {:error, error} -> {:error, error}
          end
      end
    end
  end

  def slice_lines(content, opts) do
    offset = opts |> Keyword.get(:offset, 0) |> int_or(0) |> max(0)
    limit = opts |> Keyword.get(:limit, 2_000) |> int_or(2_000)

    lines =
      content
      |> String.replace("\r\n", "\n")
      |> String.replace("\r", "\n")
      |> String.split("\n")

    lines =
      if List.last(lines) == "" do
        Enum.drop(lines, -1)
      else
        lines
      end

    if offset > length(lines) do
      {:error, "Line offset #{offset} exceeds file length (#{length(lines)} lines)"}
    else
      lines
      |> Enum.drop(offset)
      |> Enum.take(max(limit, 0))
      |> Enum.join("\n")
    end
  end

  def maybe_slice_lines({:error, error}), do: {:error, error}
  def maybe_slice_lines(content), do: {:ok, content}

  def slice_read_response(file_data, offset, limit) do
    case file_data |> normalize_file_data() |> read_content(offset: offset, limit: limit) do
      {:ok, content} -> content
      {:error, error} -> %Filesystem.ReadResult{error: error}
    end
  end

  def binary_content?(bytes),
    do: not String.valid?(bytes) or :binary.match(bytes, <<0>>) != :nomatch

  def now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  def error_string(:enoent), do: "file_not_found"
  def error_string(:eacces), do: "permission_denied"
  def error_string(:eisdir), do: "is_directory"
  def error_string(reason) when is_binary(reason), do: reason
  def error_string(reason), do: inspect(reason)

  defp int_or(value, _default) when is_integer(value), do: value
  defp int_or(value, _default) when is_binary(value), do: String.to_integer(value)
  defp int_or(_value, default), do: default
end
