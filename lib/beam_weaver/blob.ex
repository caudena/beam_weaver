defmodule BeamWeaver.Blob do
  @moduledoc """
  Binary or text source used by document loaders.
  """

  alias BeamWeaver.Core.Error

  defstruct [:id, :source, :path, :data, :mimetype, metadata: %{}, encoding: "utf-8"]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          source: String.t() | nil,
          path: String.t() | nil,
          data: binary() | nil,
          mimetype: String.t() | nil,
          metadata: map(),
          encoding: String.t()
        }

  def from_data(data, opts \\ []) when is_binary(data) do
    source = Keyword.get(opts, :source) || Keyword.get(opts, :path)

    {:ok,
     %__MODULE__{
       id: id(Keyword.get(opts, :id)),
       data: data,
       source: source,
       path: Keyword.get(opts, :path),
       mimetype: Keyword.get(opts, :mimetype) || Keyword.get(opts, :mime_type),
       metadata: Keyword.get(opts, :metadata, %{}),
       encoding: Keyword.get(opts, :encoding, "utf-8")
     }}
  end

  def from_path(path, opts \\ []) when is_binary(path) do
    if File.regular?(path) do
      mimetype =
        Keyword.get(opts, :mimetype) || Keyword.get(opts, :mime_type) ||
          if(Keyword.get(opts, :guess_type, true), do: guess_mimetype(path), else: nil)

      {:ok,
       %__MODULE__{
         id: id(Keyword.get(opts, :id)),
         source: path,
         path: path,
         mimetype: mimetype,
         metadata: Keyword.get(opts, :metadata, %{}) |> Map.put_new(:source, path),
         encoding: Keyword.get(opts, :encoding, "utf-8")
       }}
    else
      {:error, Error.new(:blob_not_found, "blob path does not exist", %{path: path})}
    end
  end

  def read(%__MODULE__{data: data}) when is_binary(data), do: {:ok, data}
  def read(%__MODULE__{source: source}) when is_binary(source), do: File.read(source)
  def read(_blob), do: {:error, Error.new(:invalid_blob, "blob has no data or source")}

  def as_string(%__MODULE__{} = blob), do: read(blob)

  def as_bytes(%__MODULE__{} = blob), do: read(blob)

  def as_bytes_io(%__MODULE__{path: path}, fun) when is_binary(path) and is_function(fun, 1) do
    File.open(path, [:read, :binary], fun)
  end

  def as_bytes_io(%__MODULE__{} = blob, fun) when is_function(fun, 1) do
    with {:ok, data} <- as_bytes(blob),
         {:ok, io} <- StringIO.open(data) do
      try do
        {:ok, fun.(io)}
      after
        StringIO.close(io)
      end
    end
  end

  def source(%__MODULE__{metadata: metadata, source: source, path: path}) do
    Map.get(metadata, :source) || Map.get(metadata, "source") || source || path
  end

  def validate(%__MODULE__{data: data, source: source, path: path}) do
    if is_binary(data) or is_binary(source) or is_binary(path) do
      :ok
    else
      {:error, Error.new(:invalid_blob, "blob requires data or path")}
    end
  end

  def repr(%__MODULE__{} = blob) do
    ["Blob", blob.id, source(blob)]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(" ", &to_string/1)
  end

  defp id(nil), do: nil
  defp id(value), do: to_string(value)

  defp guess_mimetype(path) do
    case Path.extname(path) |> String.downcase() do
      ".txt" -> "text/plain"
      ".md" -> "text/markdown"
      ".json" -> "application/json"
      ".jsonl" -> "application/jsonl"
      ".csv" -> "text/csv"
      ".tsv" -> "text/tab-separated-values"
      ".html" -> "text/html"
      ".htm" -> "text/html"
      ".pdf" -> "application/pdf"
      _other -> nil
    end
  end
end
