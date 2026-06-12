defmodule BeamWeaver.Prompt.Loader.Files do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Prompt.Loader.Codec
  alias BeamWeaver.Result

  def reject_hub_path("lc://" <> _rest) do
    {:error, Error.new(:unsupported_prompt_source, "LangChain Hub prompt paths are not supported")}
  end

  def reject_hub_path(_path), do: :ok

  def read_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, reason} ->
        {:error,
         Error.new(:prompt_load_error, "prompt file could not be read", %{
           path: path,
           reason: reason
         })}
    end
  end

  def read_text_file(path, opts) do
    with {:ok, contents} <- read_file(path) do
      decode_text(contents, Keyword.get(opts, :encoding, :utf8))
    end
  end

  def read_relative_text(path, opts, extensions) do
    with :ok <- validate_relative_path(path, opts),
         full_path <- resolve_relative_path(path, opts),
         :ok <- validate_extension(full_path, extensions) do
      read_file(full_path)
    end
  end

  defp decode_text(contents, encoding) when encoding in [nil, :utf8, "utf8", "utf-8"] do
    if String.valid?(contents) do
      {:ok, contents}
    else
      {:error,
       Error.new(:prompt_encoding_error, "prompt file is not valid UTF-8", %{
         encoding: encoding
       })}
    end
  end

  defp decode_text(contents, encoding)
       when encoding in [:cp1252, "cp1252", :"windows-1252", "windows-1252"] do
    decode_cp1252(contents)
  end

  defp decode_text(_contents, encoding) do
    {:error,
     Error.new(:unsupported_prompt_encoding, "prompt file encoding is not supported", %{
       encoding: encoding,
       supported: [:utf8, :cp1252]
     })}
  end

  @cp1252_controls %{
    0x80 => 0x20AC,
    0x82 => 0x201A,
    0x83 => 0x0192,
    0x84 => 0x201E,
    0x85 => 0x2026,
    0x86 => 0x2020,
    0x87 => 0x2021,
    0x88 => 0x02C6,
    0x89 => 0x2030,
    0x8A => 0x0160,
    0x8B => 0x2039,
    0x8C => 0x0152,
    0x8E => 0x017D,
    0x91 => 0x2018,
    0x92 => 0x2019,
    0x93 => 0x201C,
    0x94 => 0x201D,
    0x95 => 0x2022,
    0x96 => 0x2013,
    0x97 => 0x2014,
    0x98 => 0x02DC,
    0x99 => 0x2122,
    0x9A => 0x0161,
    0x9B => 0x203A,
    0x9C => 0x0153,
    0x9E => 0x017E,
    0x9F => 0x0178
  }

  defp decode_cp1252(contents) do
    contents
    |> :binary.bin_to_list()
    |> Result.traverse(fn byte ->
      cond do
        byte in [0x81, 0x8D, 0x8F, 0x90, 0x9D] ->
          {:error,
           Error.new(:prompt_encoding_error, "prompt file contains invalid CP-1252 bytes", %{
             byte: byte
           })}

        byte >= 0x80 and byte <= 0x9F ->
          {:ok, Map.fetch!(@cp1252_controls, byte)}

        true ->
          {:ok, byte}
      end
    end)
    |> case do
      {:ok, codepoints} ->
        {:ok, List.to_string(codepoints)}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp validate_relative_path(path, opts) do
    if Keyword.get(opts, :allow_dangerous_paths, false) do
      :ok
    else
      cond do
        Path.type(path) == :absolute ->
          {:error, Error.new(:unsafe_prompt_path, "absolute prompt paths are not allowed", %{path: path})}

        ".." in Path.split(path) ->
          {:error,
           Error.new(:unsafe_prompt_path, "prompt paths may not contain '..' components", %{
             path: path
           })}

        true ->
          :ok
      end
    end
  end

  defp resolve_relative_path(path, opts) do
    base_dir = Keyword.get(opts, :base_dir, File.cwd!())

    if Path.type(path) == :absolute do
      Path.expand(path)
    else
      Path.expand(path, base_dir)
    end
  end

  defp validate_extension(path, extensions) do
    resolved_path = Codec.resolve_existing_path(path)

    if Path.extname(path) in extensions and Path.extname(resolved_path) in extensions do
      :ok
    else
      {:error,
       Error.new(
         :unsupported_prompt_format,
         "referenced prompt file has an unsupported suffix",
         %{
           path: path,
           extensions: extensions
         }
       )}
    end
  end
end
