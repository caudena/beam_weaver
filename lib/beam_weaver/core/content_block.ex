defmodule BeamWeaver.Core.ContentBlock do
  @moduledoc """
  Typed content blocks used by messages and streaming chunks.
  """

  import BeamWeaver.MapAccess, only: [get: 2]

  alias BeamWeaver.Core.ContentBlock.Normalizer
  alias BeamWeaver.Core.Error
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

  @block_structs [Text, PlainText, Image, Audio, File, Video, Reasoning, Citation, ToolResult, Unknown]

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

  @replayable_reasoning_names ~w(thinking thinking_delta signature_delta redacted_thinking)
  @replayable_reasoning_types @replayable_reasoning_names ++ Enum.map(@replayable_reasoning_names, &String.to_atom/1)
  @reasoning_types [:reasoning, "reasoning" | @replayable_reasoning_types]
  @data_types Enum.flat_map(~w(image image_url audio file video)a, &[&1, Atom.to_string(&1)])

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
    get(block, :type) in @data_types or
      match?("data:" <> _rest, get(block, :url)) or match?("data:" <> _rest, get(block, :data_uri)) or
      not is_nil(get(block, :base64)) or not is_nil(get(block, :data))
  end

  def data?("data:" <> _rest), do: true
  def data?(_block), do: false

  @doc """
  Returns true when a content block represents provider reasoning.

  The predicate accepts typed blocks as well as normalized and provider-native
  map shapes so message rewriting and stream collection share one definition.
  """
  @spec reasoning?(term()) :: boolean()
  def reasoning?(%Reasoning{}), do: true

  def reasoning?(%Unknown{provider_type: provider_type, value: value}) do
    reasoning_type?(provider_type) or provider_reasoning_type?(value)
  end

  def reasoning?(block) when is_map(block) do
    reasoning_type?(get(block, :type)) or
      reasoning_type?(get(block, :provider_type)) or
      provider_reasoning_type?(get(block, :raw_provider_block))
  end

  def reasoning?(_block), do: false

  @doc """
  Returns true when a reasoning block carries provider replay material.

  Signed and redacted thinking must survive normal stream collection so it can
  be sent back on the next provider turn. Plain display-only reasoning remains
  non-replayable.
  """
  @spec replayable_reasoning?(term()) :: boolean()
  def replayable_reasoning?(%Reasoning{metadata: metadata}), do: signed?(metadata)

  def replayable_reasoning?(%Unknown{provider_type: provider_type, value: value}) do
    replayable_reasoning_type?(provider_type) or provider_replayable_reasoning?(value)
  end

  def replayable_reasoning?(block) when is_map(block) do
    replayable_reasoning_type?(get(block, :type)) or
      replayable_reasoning_type?(get(block, :provider_type)) or
      signed?(get(block, :metadata)) or
      signed?(block) or
      provider_replayable_reasoning?(get(block, :raw_provider_block))
  end

  def replayable_reasoning?(_block), do: false

  @doc """
  Converts a content-block-like value into a typed content block.
  """
  @spec from(term()) :: {:ok, term()} | {:error, Error.t()}
  def from("data:" <> _rest = uri), do: from_data_uri(uri)
  def from(text) when is_binary(text), do: {:ok, text(text)}
  def from(%module{} = block) when module in @block_structs, do: {:ok, block}
  def from(map) when is_map(map) and not is_struct(map), do: Normalizer.from_map(map)

  def from(value),
    do:
      {:error,
       Error.new(:invalid_content_block, "value cannot be converted to a content block", %{value: inspect(value)})}

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
  def parse_data_uri("data:" <> rest) do
    case String.split(rest, ",", parts: 2) do
      [header, payload] ->
        media_type = media_type(header)
        encoding = if "base64" in String.split(header, ";"), do: :base64, else: :url_encoded

        with {:ok, data} <- decode_data_payload(payload, encoding) do
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
      fields = %{data: parsed.data, mime_type: parsed.media_type, metadata: metadata}

      case content_kind(parsed.media_type) do
        :image -> {:ok, image(fields)}
        :audio -> {:ok, audio(fields)}
        :video -> {:ok, video(fields)}
        :file -> {:ok, file(fields)}
        :text -> {:ok, text(parsed.data, metadata)}
        :unknown -> {:ok, unknown("data_uri", parsed, metadata)}
      end
    end
  end

  defp media_type(header) do
    case header |> String.split(";") |> hd() do
      "" -> "text/plain"
      type -> type
    end
  end

  defp decode_data_payload(payload, :base64) do
    case Base.decode64(payload, ignore: :whitespace) do
      {:ok, _decoded} ->
        {:ok, payload}

      :error ->
        {:error, Error.new(:invalid_content_block, "data URI base64 payload is invalid")}
    end
  end

  defp decode_data_payload(payload, :url_encoded), do: {:ok, URI.decode(payload)}

  defp content_kind("image/" <> _rest), do: :image
  defp content_kind("audio/" <> _rest), do: :audio
  defp content_kind("video/" <> _rest), do: :video
  defp content_kind("text/" <> _rest), do: :text
  defp content_kind("application/" <> _rest), do: :file
  defp content_kind(_media_type), do: :unknown

  defp reasoning_type?(type), do: type in @reasoning_types
  defp replayable_reasoning_type?(type), do: type in @replayable_reasoning_types

  defp provider_reasoning_type?(value) when is_map(value),
    do: reasoning_type?(get(value, :type))

  defp provider_reasoning_type?(_value), do: false

  defp provider_replayable_reasoning?(value) when is_map(value),
    do: replayable_reasoning_type?(get(value, :type)) or signed?(value)

  defp provider_replayable_reasoning?(_value), do: false

  defp signed?(value) when is_map(value),
    do: not is_nil(get(value, :signature)) or not is_nil(get(value, :encrypted_content))

  defp signed?(_value), do: false
end
