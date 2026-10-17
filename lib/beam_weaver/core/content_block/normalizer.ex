defmodule BeamWeaver.Core.ContentBlock.Normalizer do
  @moduledoc false

  import BeamWeaver.MapAccess, only: [get: 2]

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.MapShape

  @known_map_types ~w(custom_tool_call custom_tool_call_output code_interpreter_call file_search_call function_call
                      guard_content image_generation_call json mcp_approval_request mcp_call mcp_list_tools media
                      refusal server_tool_result shell_call shell_call_output text_block text_block_delta
                      tool_search_call tool_search_output tool_call tool_call_chunk tool_use web_search_call
                      server_tool_call server_tool_call_chunk)a
  @known_map_type_names Map.new(@known_map_types, &{Atom.to_string(&1), &1})

  @spec from_map(map()) :: {:ok, term()} | {:error, BeamWeaver.Core.Error.t()}
  def from_map(map) do
    type = get(map, :type)

    cond do
      provider_image_bytes?(map) ->
        {:ok, provider_image_bytes_block(map)}

      match?("data:" <> _rest, get(map, :url)) ->
        ContentBlock.from_data_uri(get(map, :url), metadata(map))

      match?("data:" <> _rest, get(map, :data_uri)) ->
        ContentBlock.from_data_uri(get(map, :data_uri), metadata(map))

      type in [:text, "text", "input_text", "output_text"] ->
        {:ok, text_block(map)}

      type in [:"text-plain", "text-plain"] ->
        {:ok,
         %{
           type: :"text-plain",
           text: get(map, :text),
           raw_provider_block: get(map, :raw_provider_block)
         }
         |> MapShape.reject_nil_values()}

      type in [:plain_text, "plain_text"] ->
        {:ok, ContentBlock.plain_text(get(map, :text) || "", metadata(map))}

      is_nil(type) and is_binary(get(map, :text)) ->
        {:ok, ContentBlock.text(get(map, :text), metadata(map))}

      is_nil(type) and is_binary(get(map, :content)) ->
        {:ok, ContentBlock.text(get(map, :content), metadata(map))}

      type in [:image_url, "image_url", :input_image, "input_image"] ->
        {:ok, image_url_block(map)}

      type in [:image, "image"] ->
        {:ok, image_block(map)}

      type in [:audio, "audio", :input_audio, "input_audio"] ->
        {:ok, audio_block(map)}

      type in [:video, "video"] ->
        {:ok, ContentBlock.video(media_fields(map))}

      type in [:file, "file", :file_url, "file_url"] ->
        file_block(map)

      type in [:reasoning, "reasoning"] ->
        {:ok, reasoning_block(map)}

      type in [:citation, "citation"] ->
        {:ok,
         ContentBlock.citation(%{
           url: get(map, :url),
           title: get(map, :title),
           text: get(map, :text),
           start_index: get(map, :start_index),
           end_index: get(map, :end_index),
           metadata: metadata(map)
         })}

      type in [:tool_result, "tool_result"] ->
        {:ok,
         ContentBlock.tool_result(%{
           tool_call_id: get(map, :tool_call_id) || get(map, :tool_use_id) || get(map, :id),
           content: project_nested_content(get(map, :content)),
           artifact: get(map, :artifact),
           metadata: metadata(map)
         })}

      known_map_type?(type) ->
        {:ok, normalize_known_map_block(map, type)}

      true ->
        {:ok, ContentBlock.unknown(to_string(type || "unknown"), map, metadata(map))}
    end
  end

  defp metadata(map), do: get(map, :metadata) || %{}

  defp media_fields(map) do
    %{
      url: get(map, :url),
      file_id: get(map, :file_id),
      data: get(map, :data) || get(map, :base64),
      mime_type: get(map, :mime_type) || get(map, :format),
      metadata: metadata(map)
    }
  end

  defp known_map_type?(type) when is_atom(type), do: type in @known_map_types
  defp known_map_type?(type) when is_binary(type), do: Map.has_key?(@known_map_type_names, type)
  defp known_map_type?(_type), do: false

  defp normalize_known_map_block(map, type) do
    type = normalize_type(type)

    case type do
      :function_call -> function_call_block(map)
      :tool_call -> tool_call_block(map, :tool_call)
      :tool_use -> tool_call_block(map, :tool_use)
      :tool_call_chunk -> tool_call_chunk_block(map)
      :server_tool_call -> server_tool_call_block(map)
      :server_tool_call_chunk -> server_tool_call_chunk_block(map)
      :server_tool_result -> server_tool_result_block(map)
      :text_block -> text_block_delta_block(map, :text_block)
      :text_block_delta -> text_block_delta_block(map, :text_block_delta)
      :json -> json_block(map)
      :guard_content -> guard_content_block(map)
      :media -> media_block(map)
      :refusal -> refusal_block(map)
      type -> provider_output_block(map, type)
    end
  end

  defp normalize_type(type) when is_atom(type), do: type
  defp normalize_type(type) when is_binary(type), do: Map.fetch!(@known_map_type_names, type)

  defp text_block(map) do
    %{
      type: :text,
      id: get(map, :id),
      index: get(map, :index),
      text: get(map, :text) || get(map, :content) || "",
      phase: get(map, :phase),
      annotations: get(map, :annotations),
      cache_control: get(map, :cache_control),
      thought_signature: thought_signature(map),
      metadata: non_empty_metadata(map),
      raw_provider_block: get(map, :raw_provider_block)
    }
    |> MapShape.reject_nil_values()
  end

  defp image_url_block(map) do
    image_url = get(map, :image_url)

    {url, detail} =
      cond do
        is_map(image_url) ->
          {get(image_url, :url), get(image_url, :detail)}

        is_binary(image_url) ->
          {image_url, get(map, :detail)}

        true ->
          {get(map, :url), get(map, :detail)}
      end

    ContentBlock.image(%{media_fields(map) | url: url, metadata: put_metadata_detail(metadata(map), detail)})
  end

  defp image_block(map) do
    case get(map, :source) do
      %{} = source -> source_image_block(map, source)
      _other -> plain_image_block(map)
    end
  end

  # An Anthropic-style image names its source: base64 data, a URL or an
  # uploaded file. One that lacks what its source needs stays an unknown
  # block instead of becoming an empty image.
  defp source_image_block(map, source) do
    fields =
      case get(source, :type) do
        type when type in [:url, "url"] -> %{url: get(source, :url)}
        type when type in [:file, "file"] -> %{file_id: get(source, :file_id)}
        type when type in [nil, :base64, "base64"] -> base64_source(source)
        _other -> %{}
      end

    if Enum.any?(Map.values(fields), &is_binary/1),
      do: ContentBlock.image(Map.put(fields, :metadata, metadata(map))),
      else: ContentBlock.unknown("image", map, metadata(map))
  end

  defp base64_source(source) do
    case {get(source, :data), get(source, :media_type)} do
      {data, mime_type} when is_binary(data) and is_binary(mime_type) -> %{data: data, mime_type: mime_type}
      _other -> %{}
    end
  end

  defp plain_image_block(map) do
    if get(map, :source_type) == "base64",
      do: ContentBlock.image(%{media_fields(map) | data: get(map, :data), mime_type: get(map, :mime_type)}),
      else: ContentBlock.image(media_fields(map))
  end

  defp audio_block(map) do
    input_audio = get(map, :input_audio)

    if is_map(get(map, :audio)) or is_binary(get(map, :audio)) do
      %{
        type: :audio,
        id: get(map, :id),
        audio: get(map, :audio),
        raw_provider_block: get(map, :raw_provider_block)
      }
      |> MapShape.reject_nil_values()
    else
      fields = media_fields(map)

      ContentBlock.audio(
        if is_map(input_audio),
          do: %{
            fields
            | data: get(input_audio, :data),
              mime_type: get(input_audio, :mime_type) || get(input_audio, :format)
          },
          else: fields
      )
    end
  end

  # The file can sit in a nested `file` map, as in OpenAI Chat Completions and
  # Z.ai parts: `%{"type" => "file", "file" => %{"file_url" => url}}`, or
  # `"file_id"`, or `"file_data"` with a data URL. Z.ai's older part is
  # `%{"type" => "file_url", "file_url" => %{"url" => url}}`. A data URL where
  # a URL goes is the file's data.
  defp file_block(map) do
    source =
      case get(map, :file) do
        file when is_map(file) -> file
        _missing -> map
      end

    data = get(source, :file_data) || get(source, :data) || get(source, :base64)

    url = url_value(get(source, :url) || get(source, :file_url) || get(map, :url))

    {data, url} = if is_nil(data) and match?("data:" <> _rest, url), do: {url, nil}, else: {data, url}

    with {:ok, data, data_mime_type} <- file_data(data) do
      {:ok,
       ContentBlock.file(%{
         file_id: get(source, :file_id),
         filename: get(source, :filename),
         url: url,
         data: data,
         mime_type: get(map, :mime_type) || get(source, :mime_type) || data_mime_type,
         metadata: metadata(map)
       })}
    end
  end

  # File data is base64; a data URL gives its payload and media type.
  defp file_data("data:" <> _rest = uri) do
    with {:ok, %{media_type: media_type, encoding: encoding, data: data}} <- ContentBlock.parse_data_uri(uri) do
      {:ok, if(encoding == :base64, do: data, else: Base.encode64(data)), media_type}
    end
  end

  defp file_data(data), do: {:ok, data, nil}

  defp url_value(url) when is_binary(url), do: url
  defp url_value(%{} = value), do: get(value, :url)
  defp url_value(_value), do: nil

  defp reasoning_block(map) do
    reasoning = get(map, :reasoning) || get(map, :text)
    metadata = put_metadata_thought_signature(metadata(map), thought_signature(map))

    if is_binary(reasoning) and is_nil(get(map, :id)) and
         is_nil(get(map, :summary)) and is_nil(get(map, :status)) and
         is_nil(get(map, :raw_provider_block)) do
      ContentBlock.reasoning(reasoning, metadata)
    else
      %{
        type: :reasoning,
        id: get(map, :id),
        reasoning: reasoning,
        summary: get(map, :summary),
        status: get(map, :status),
        encrypted_content: get(map, :encrypted_content),
        thought_signature: thought_signature(map),
        raw_provider_block: get(map, :raw_provider_block)
      }
      |> MapShape.reject_nil_values()
    end
  end

  defp function_call_block(map) do
    %{
      type: :function_call,
      id: get(map, :id),
      provider_id: get(map, :provider_id),
      call_id: get(map, :call_id),
      name: get(map, :name),
      arguments: get(map, :arguments) || get(map, :args),
      status: get(map, :status),
      thought_signature: thought_signature(map),
      raw_provider_block: get(map, :raw_provider_block)
    }
    |> MapShape.reject_nil_values()
  end

  defp tool_call_block(map, type) do
    %{
      type: type,
      id: get(map, :id),
      provider_id: get(map, :provider_id),
      call_id: get(map, :call_id),
      name: get(map, :name),
      args: get(map, :input) || get(map, :args),
      arguments: get(map, :arguments),
      thought_signature: thought_signature(map),
      raw_provider_block: get(map, :raw_provider_block)
    }
    |> MapShape.reject_nil_values()
  end

  defp tool_call_chunk_block(map) do
    %{
      type: :tool_call_chunk,
      id: get(map, :id),
      index: get(map, :index),
      name: get(map, :name),
      args: get(map, :args) || get(map, :arguments),
      tool_call_id: get(map, :tool_call_id)
    }
    |> MapShape.reject_nil_values()
  end

  defp server_tool_call_block(map) do
    %{
      type: :server_tool_call,
      id: get(map, :id),
      name: get(map, :name),
      args: get(map, :args) || %{},
      raw_provider_block: get(map, :raw_provider_block)
    }
    |> MapShape.reject_nil_values()
  end

  defp server_tool_call_chunk_block(map) do
    %{
      type: :server_tool_call_chunk,
      id: get(map, :id),
      index: get(map, :index),
      name: get(map, :name),
      args: get(map, :args)
    }
    |> MapShape.reject_nil_values()
  end

  defp server_tool_result_block(map) do
    %{
      type: :server_tool_result,
      tool_call_id: get(map, :tool_call_id) || get(map, :id),
      status: get(map, :status),
      output: get(map, :output),
      raw_provider_block: get(map, :raw_provider_block)
    }
    |> MapShape.reject_nil_values()
  end

  defp text_block_delta_block(map, type) do
    %{
      type: type,
      index: get(map, :index),
      text: get(map, :text),
      raw_provider_block: get(map, :raw_provider_block)
    }
    |> MapShape.reject_nil_values()
  end

  defp json_block(map) do
    %{
      type: :json,
      json: get(map, :json) || get(map, :data)
    }
    |> MapShape.reject_nil_values()
  end

  defp guard_content_block(map) do
    %{
      type: :guard_content,
      guard_content: project_guard_content(get(map, :guard_content))
    }
    |> MapShape.reject_nil_values()
  end

  defp media_block(map) do
    mime_type = get(map, :mime_type)
    data = get(map, :data)

    if is_binary(mime_type) and String.starts_with?(mime_type, "image/") do
      ContentBlock.image(%{
        data: encode_binary_data(data),
        mime_type: mime_type,
        metadata: metadata(map)
      })
    else
      provider_output_block(map, :media)
    end
  end

  defp refusal_block(map) do
    %{
      type: :refusal,
      id: get(map, :id),
      refusal: get(map, :refusal),
      metadata: non_empty_metadata(map),
      raw_provider_block: get(map, :raw_provider_block)
    }
    |> MapShape.reject_nil_values()
  end

  defp provider_output_block(map, type) do
    %{
      type: type,
      id: get(map, :id),
      status: get(map, :status),
      queries: get(map, :queries),
      results: get(map, :results),
      result: get(map, :result),
      action: get(map, :action),
      container_id: get(map, :container_id),
      tools: get(map, :tools),
      execution: get(map, :execution),
      output: get(map, :output),
      call_id: get(map, :call_id),
      name: get(map, :name),
      raw_provider_block: get(map, :raw_provider_block) || map
    }
    |> MapShape.reject_nil_values()
  end

  defp non_empty_metadata(map) do
    case metadata(map) do
      metadata when is_map(metadata) and map_size(metadata) > 0 -> metadata
      _metadata -> nil
    end
  end

  defp provider_image_bytes?(map) do
    image = get(map, :image)
    source = if is_map(image), do: get(image, :source), else: nil

    is_map(source) and is_binary(get(source, :bytes))
  end

  defp provider_image_bytes_block(map) do
    image = get(map, :image)
    source = get(image, :source)
    format = get(image, :format) || "jpeg"

    ContentBlock.image(%{
      data: Base.encode64(get(source, :bytes)),
      mime_type: "image/#{format}",
      metadata: metadata(map)
    })
  end

  defp thought_signature(map), do: signature(map) || signature(metadata(map))

  defp signature(map) when is_map(map),
    do: get(map, :thought_signature) || Map.get(map, "thoughtSignature") || Map.get(map, :thoughtSignature)

  defp signature(_value), do: nil

  defp put_metadata_thought_signature(metadata, signature) when is_binary(signature) and signature != "" do
    Map.put(metadata, :thought_signature, signature)
  end

  defp put_metadata_thought_signature(metadata, _signature), do: metadata

  defp encode_binary_data(data) when is_binary(data), do: Base.encode64(data)
  defp encode_binary_data(data), do: data

  defp project_guard_content(%{} = guard_content) do
    %{
      text: get(guard_content, :text),
      type: get(guard_content, :type),
      raw_provider_block: guard_content
    }
    |> MapShape.reject_nil_values()
  end

  defp project_guard_content(value), do: value

  defp project_nested_content(content) when is_list(content) do
    case ContentBlock.normalize_many(content) do
      {:ok, blocks} -> blocks
      {:error, _error} -> content
    end
  end

  defp project_nested_content(content), do: content

  defp put_metadata_detail(map, nil), do: map

  defp put_metadata_detail(map, detail) when is_map(map) do
    if map_size(map) == 0 or Enum.all?(map, fn {key, _value} -> is_atom(key) end) do
      Map.put(map, :detail, detail)
    else
      Map.put(map, "detail", detail)
    end
  end
end
