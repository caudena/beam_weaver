defmodule BeamWeaver.Core.ContentBlock do
  @moduledoc """
  Typed content blocks used by messages and streaming chunks.
  """

  alias BeamWeaver.Core.ContentBlockLike
  alias BeamWeaver.Core.Error
  alias BeamWeaver.MapAccess
  alias BeamWeaver.Result

  defmodule Text do
    @moduledoc false
    defstruct [:text, type: :text, metadata: %{}]
  end

  defmodule PlainText do
    @moduledoc false
    defstruct [:text, type: :plain_text, metadata: %{}]
  end

  defmodule Image do
    @moduledoc false
    defstruct [:url, :file_id, :data, :mime_type, type: :image, metadata: %{}]
  end

  defmodule Audio do
    @moduledoc false
    defstruct [:url, :file_id, :data, :mime_type, type: :audio, metadata: %{}]
  end

  defmodule File do
    @moduledoc false
    defstruct [:file_id, :filename, :url, :data, :mime_type, type: :file, metadata: %{}]
  end

  defmodule Video do
    @moduledoc false
    defstruct [:url, :file_id, :data, :mime_type, type: :video, metadata: %{}]
  end

  defmodule Reasoning do
    @moduledoc false
    defstruct [:reasoning, type: :reasoning, metadata: %{}]
  end

  defmodule Citation do
    @moduledoc false
    defstruct [:url, :title, :text, :start_index, :end_index, type: :citation, metadata: %{}]
  end

  defmodule ToolResult do
    @moduledoc false
    defstruct [:tool_call_id, :content, :artifact, type: :tool_result, metadata: %{}]
  end

  defmodule Unknown do
    @moduledoc false
    defstruct [:provider_type, :value, type: :unknown, metadata: %{}]
  end

  @known_types [
    :text,
    :plain_text,
    :image,
    :audio,
    :file,
    :video,
    :reasoning,
    :citation,
    :tool_result,
    :tool_call,
    :tool_call_chunk,
    :server_tool_call,
    :server_tool_call_chunk,
    :server_tool_result,
    :unknown
  ]

  @doc """
  Returns the stable set of content block types BeamWeaver understands natively.
  """
  @spec known_types() :: [atom()]
  def known_types, do: @known_types

  def text(text, metadata \\ %{}), do: %Text{text: text, metadata: metadata}
  def plain_text(text, metadata \\ %{}), do: %PlainText{text: text, metadata: metadata}
  def image(opts), do: struct(Image, opts)
  def audio(opts), do: struct(Audio, opts)
  def video(opts), do: struct(Video, opts)
  def file(opts), do: struct(File, opts)
  def reasoning(text, metadata \\ %{}), do: %Reasoning{reasoning: text, metadata: metadata}
  def citation(opts), do: struct(Citation, opts)
  def tool_result(opts), do: struct(ToolResult, opts)

  def unknown(provider_type, value, metadata \\ %{}),
    do: %Unknown{provider_type: provider_type, value: value, metadata: metadata}

  @doc """
  Returns true when a block carries binary or remote data rather than plain text.
  """
  @spec data?(term()) :: boolean()
  def data?(%Image{}), do: true
  def data?(%Audio{}), do: true
  def data?(%File{}), do: true
  def data?(%Video{}), do: true

  def data?(block) when is_map(block) do
    type = get(block, :type)

    type in [
      :image,
      "image",
      :image_url,
      "image_url",
      :audio,
      "audio",
      :file,
      "file",
      :video,
      "video"
    ] or
      data_uri?(get(block, :url)) or data_uri?(get(block, :data_uri)) or
      not is_nil(get(block, :base64)) or not is_nil(get(block, :data))
  end

  def data?("data:" <> _rest), do: true
  def data?(_block), do: false

  @doc """
  Converts a content-block-like value into a typed content block.
  """
  @spec from(term()) :: {:ok, term()} | {:error, Error.t()}
  def from(value), do: ContentBlockLike.to_content_block(value)

  @doc """
  Converts a list of content-block-like values into typed content blocks.
  """
  @spec normalize_many([term()]) :: {:ok, [term()]} | {:error, Error.t()}
  def normalize_many(values) when is_list(values) do
    Result.traverse(values, &from/1)
  end

  def normalize_many(_values),
    do: {:error, Error.new(:invalid_content_block, "content blocks must be a list")}

  @doc """
  Parses a `data:` URI without creating atoms from untrusted input.

  Base64 payloads are validated but kept encoded, because provider request builders
  expect base64 strings at the boundary. Percent-encoded payloads are decoded.
  """
  @spec parse_data_uri(String.t()) :: {:ok, map()} | {:error, Error.t()}
  def parse_data_uri("data:" <> rest = uri) do
    case String.split(rest, ",", parts: 2) do
      [header, payload] ->
        media_type = media_type(header)
        encoding = data_uri_encoding(header)

        with {:ok, data} <- decode_data_payload(payload, encoding, uri) do
          {:ok,
           %{
             media_type: media_type,
             encoding: encoding,
             data: data
           }}
        end

      _other ->
        {:error, Error.new(:invalid_content_block, "data URI is missing a payload")}
    end
  end

  def parse_data_uri(_value),
    do: {:error, Error.new(:invalid_content_block, "expected a data URI")}

  @doc """
  Builds the appropriate typed content block from a `data:` URI.
  """
  @spec from_data_uri(String.t(), map()) :: {:ok, term()} | {:error, Error.t()}
  def from_data_uri(uri, metadata \\ %{}) do
    with {:ok, parsed} <- parse_data_uri(uri) do
      metadata = Map.merge(%{source: :data_uri, encoding: parsed.encoding}, metadata)

      case content_kind(parsed.media_type) do
        :image ->
          {:ok, image(%{data: parsed.data, mime_type: parsed.media_type, metadata: metadata})}

        :audio ->
          {:ok, audio(%{data: parsed.data, mime_type: parsed.media_type, metadata: metadata})}

        :video ->
          {:ok, video(%{data: parsed.data, mime_type: parsed.media_type, metadata: metadata})}

        :file ->
          {:ok, file(%{data: parsed.data, mime_type: parsed.media_type, metadata: metadata})}

        :text ->
          {:ok, text(parsed.data, metadata)}

        :unknown ->
          {:ok, unknown("data_uri", parsed, metadata)}
      end
    end
  end

  defp media_type(""), do: "text/plain"

  defp media_type(header) do
    header
    |> String.split(";")
    |> List.first()
    |> case do
      "" -> "text/plain"
      nil -> "text/plain"
      type -> type
    end
  end

  defp data_uri_encoding(header) do
    if header |> String.split(";") |> Enum.any?(&(&1 == "base64")) do
      :base64
    else
      :url_encoded
    end
  end

  defp decode_data_payload(payload, :base64, _uri) do
    case Base.decode64(payload, ignore: :whitespace) do
      {:ok, _decoded} ->
        {:ok, payload}

      :error ->
        {:error, Error.new(:invalid_content_block, "data URI base64 payload is invalid")}
    end
  end

  defp decode_data_payload(payload, :url_encoded, _uri), do: {:ok, URI.decode(payload)}

  defp content_kind("image/" <> _rest), do: :image
  defp content_kind("audio/" <> _rest), do: :audio
  defp content_kind("video/" <> _rest), do: :video
  defp content_kind("text/" <> _rest), do: :text
  defp content_kind("application/" <> _rest), do: :file
  defp content_kind(_media_type), do: :unknown

  @doc false
  def get(map, key) when is_map(map), do: MapAccess.get(map, key)

  defp data_uri?("data:" <> _rest), do: true
  defp data_uri?(_value), do: false
end
