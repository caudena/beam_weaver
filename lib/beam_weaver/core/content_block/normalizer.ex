defmodule BeamWeaver.Core.ContentBlock.Normalizer do
  @moduledoc false

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.MapShape

  @known_map_types %{
    "custom_tool_call" => :custom_tool_call,
    "custom_tool_call_output" => :custom_tool_call_output,
    "file_search_call" => :file_search_call,
    "function_call" => :function_call,
    "guard_content" => :guard_content,
    "image_generation_call" => :image_generation_call,
    "json" => :json,
    "mcp_approval_request" => :mcp_approval_request,
    "mcp_call" => :mcp_call,
    "mcp_list_tools" => :mcp_list_tools,
    "media" => :media,
    "refusal" => :refusal,
    "server_tool_result" => :server_tool_result,
    "text_block" => :text_block,
    "text_block_delta" => :text_block_delta,
    "tool_search_call" => :tool_search_call,
    "tool_search_output" => :tool_search_output,
    "tool_call" => :tool_call,
    "tool_call_chunk" => :tool_call_chunk,
    "tool_use" => :tool_use,
    "web_search_call" => :web_search_call,
    "server_tool_call" => :server_tool_call,
    "server_tool_call_chunk" => :server_tool_call_chunk
  }

  @spec from_map(map()) :: {:ok, term()}
  def from_map(map) do
    type = ContentBlock.get(map, :type)

    cond do
      provider_image_bytes?(map) ->
        {:ok, provider_image_bytes_block(map)}

      data_uri?(ContentBlock.get(map, :url)) ->
        ContentBlock.from_data_uri(ContentBlock.get(map, :url), metadata(map))

      data_uri?(ContentBlock.get(map, :data_uri)) ->
        ContentBlock.from_data_uri(ContentBlock.get(map, :data_uri), metadata(map))

      type in [:text, "text", "input_text", "output_text"] ->
        {:ok, text_block(map)}

      type in [:"text-plain", "text-plain"] ->
        {:ok,
         %{
           type: :"text-plain",
           text: ContentBlock.get(map, :text),
           raw_provider_block: ContentBlock.get(map, :raw_provider_block)
         }
         |> MapShape.reject_nil_values()}

      type in [:plain_text, "plain_text"] ->
        {:ok, ContentBlock.plain_text(ContentBlock.get(map, :text) || "")}

      is_nil(type) and is_binary(ContentBlock.get(map, :text)) ->
        {:ok, ContentBlock.text(ContentBlock.get(map, :text))}

      is_nil(type) and is_binary(ContentBlock.get(map, :content)) ->
        {:ok, ContentBlock.text(ContentBlock.get(map, :content))}

      type in [:image_url, "image_url", :input_image, "input_image"] ->
        {:ok, image_url_block(map)}

      type in [:image, "image"] ->
        {:ok, image_block(map)}

      type in [:audio, "audio", :input_audio, "input_audio"] ->
        {:ok, audio_block(map)}

      type in [:video, "video"] ->
        {:ok,
         ContentBlock.video(%{
           url: ContentBlock.get(map, :url),
           file_id: ContentBlock.get(map, :file_id),
           data: ContentBlock.get(map, :data) || ContentBlock.get(map, :base64),
           mime_type: ContentBlock.get(map, :mime_type) || ContentBlock.get(map, :format),
           metadata: metadata(map)
         })}

      type in [:file, "file"] ->
        {:ok, file_block(map)}

      type in [:reasoning, "reasoning"] ->
        {:ok, reasoning_block(map)}

      type in [:citation, "citation"] ->
        {:ok,
         ContentBlock.citation(%{
           url: ContentBlock.get(map, :url),
           title: ContentBlock.get(map, :title),
           text: ContentBlock.get(map, :text),
           start_index: ContentBlock.get(map, :start_index),
           end_index: ContentBlock.get(map, :end_index),
           metadata: metadata(map)
         })}

      type in [:tool_result, "tool_result"] ->
        {:ok,
         ContentBlock.tool_result(%{
           tool_call_id:
             ContentBlock.get(map, :tool_call_id) || ContentBlock.get(map, :tool_use_id) ||
               ContentBlock.get(map, :id),
           content: project_nested_content(ContentBlock.get(map, :content)),
           artifact: ContentBlock.get(map, :artifact),
           metadata: metadata(map)
         })}

      known_map_type?(type) ->
        {:ok, normalize_known_map_block(map, type)}

      true ->
        {:ok, ContentBlock.unknown(to_string(type || "unknown"), map, metadata(map))}
    end
  end

  defp data_uri?("data:" <> _rest), do: true
  defp data_uri?(_value), do: false

  defp metadata(map), do: ContentBlock.get(map, :metadata) || %{}

  defp known_map_type?(type) when is_atom(type), do: type in Map.values(@known_map_types)
  defp known_map_type?(type) when is_binary(type), do: Map.has_key?(@known_map_types, type)
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
  defp normalize_type(type) when is_binary(type), do: Map.fetch!(@known_map_types, type)

  defp text_block(map) do
    %{
      type: :text,
      id: ContentBlock.get(map, :id),
      index: ContentBlock.get(map, :index),
      text: ContentBlock.get(map, :text) || ContentBlock.get(map, :content) || "",
      phase: ContentBlock.get(map, :phase),
      annotations: ContentBlock.get(map, :annotations),
      cache_control: ContentBlock.get(map, :cache_control),
      raw_provider_block: ContentBlock.get(map, :raw_provider_block)
    }
    |> MapShape.reject_nil_values()
  end

  defp image_url_block(map) do
    image_url = ContentBlock.get(map, :image_url)

    {url, detail} =
      cond do
        is_map(image_url) ->
          {ContentBlock.get(image_url, :url), ContentBlock.get(image_url, :detail)}

        is_binary(image_url) ->
          {image_url, ContentBlock.get(map, :detail)}

        true ->
          {ContentBlock.get(map, :url), ContentBlock.get(map, :detail)}
      end

    ContentBlock.image(%{
      url: url,
      file_id: ContentBlock.get(map, :file_id),
      data: ContentBlock.get(map, :data) || ContentBlock.get(map, :base64),
      mime_type: ContentBlock.get(map, :mime_type) || ContentBlock.get(map, :format),
      metadata: put_metadata_detail(metadata(map), detail)
    })
  end

  defp image_block(map) do
    source = ContentBlock.get(map, :source)

    {data, mime_type} =
      cond do
        is_map(source) ->
          {ContentBlock.get(source, :data), ContentBlock.get(source, :media_type)}

        ContentBlock.get(map, :source_type) == "base64" ->
          {ContentBlock.get(map, :data), ContentBlock.get(map, :mime_type)}

        true ->
          {ContentBlock.get(map, :data) || ContentBlock.get(map, :base64),
           ContentBlock.get(map, :mime_type) || ContentBlock.get(map, :format)}
      end

    ContentBlock.image(%{
      url: ContentBlock.get(map, :url),
      file_id: ContentBlock.get(map, :file_id),
      data: data,
      mime_type: mime_type,
      metadata: metadata(map)
    })
  end

  defp audio_block(map) do
    input_audio = ContentBlock.get(map, :input_audio)

    if is_map(ContentBlock.get(map, :audio)) or is_binary(ContentBlock.get(map, :audio)) do
      %{
        type: :audio,
        id: ContentBlock.get(map, :id),
        audio: ContentBlock.get(map, :audio),
        raw_provider_block: ContentBlock.get(map, :raw_provider_block)
      }
      |> MapShape.reject_nil_values()
    else
      {data, mime_type} =
        if is_map(input_audio) do
          {ContentBlock.get(input_audio, :data),
           ContentBlock.get(input_audio, :mime_type) || ContentBlock.get(input_audio, :format)}
        else
          {ContentBlock.get(map, :data) || ContentBlock.get(map, :base64),
           ContentBlock.get(map, :mime_type) || ContentBlock.get(map, :format)}
        end

      ContentBlock.audio(%{
        url: ContentBlock.get(map, :url),
        file_id: ContentBlock.get(map, :file_id),
        data: data,
        mime_type: mime_type,
        metadata: metadata(map)
      })
    end
  end

  defp file_block(map) do
    file = ContentBlock.get(map, :file)

    {file_id, data, filename} =
      if is_map(file) do
        {ContentBlock.get(file, :file_id), ContentBlock.get(file, :file_data) || ContentBlock.get(file, :data),
         ContentBlock.get(file, :filename)}
      else
        {ContentBlock.get(map, :file_id), ContentBlock.get(map, :data) || ContentBlock.get(map, :base64),
         ContentBlock.get(map, :filename)}
      end

    ContentBlock.file(%{
      file_id: file_id,
      filename: filename,
      url: ContentBlock.get(map, :url),
      data: data,
      mime_type: ContentBlock.get(map, :mime_type),
      metadata: metadata(map)
    })
  end

  defp reasoning_block(map) do
    reasoning = ContentBlock.get(map, :reasoning) || ContentBlock.get(map, :text)
    metadata = put_metadata_thought_signature(metadata(map), thought_signature(map))

    if is_binary(reasoning) and is_nil(ContentBlock.get(map, :id)) and
         is_nil(ContentBlock.get(map, :summary)) and is_nil(ContentBlock.get(map, :status)) and
         is_nil(ContentBlock.get(map, :raw_provider_block)) do
      ContentBlock.reasoning(reasoning, metadata)
    else
      %{
        type: :reasoning,
        id: ContentBlock.get(map, :id),
        reasoning: reasoning,
        summary: ContentBlock.get(map, :summary),
        status: ContentBlock.get(map, :status),
        encrypted_content: ContentBlock.get(map, :encrypted_content),
        thought_signature: thought_signature(map),
        raw_provider_block: ContentBlock.get(map, :raw_provider_block)
      }
      |> MapShape.reject_nil_values()
    end
  end

  defp function_call_block(map) do
    %{
      type: :function_call,
      id: ContentBlock.get(map, :id),
      provider_id: ContentBlock.get(map, :provider_id),
      call_id: ContentBlock.get(map, :call_id),
      name: ContentBlock.get(map, :name),
      arguments: ContentBlock.get(map, :arguments) || ContentBlock.get(map, :args),
      status: ContentBlock.get(map, :status),
      thought_signature: thought_signature(map),
      raw_provider_block: ContentBlock.get(map, :raw_provider_block)
    }
    |> MapShape.reject_nil_values()
  end

  defp tool_call_block(map, type) do
    %{
      type: type,
      id: ContentBlock.get(map, :id),
      provider_id: ContentBlock.get(map, :provider_id),
      call_id: ContentBlock.get(map, :call_id),
      name: ContentBlock.get(map, :name),
      args: ContentBlock.get(map, :input) || ContentBlock.get(map, :args),
      arguments: ContentBlock.get(map, :arguments),
      thought_signature: thought_signature(map),
      raw_provider_block: ContentBlock.get(map, :raw_provider_block)
    }
    |> MapShape.reject_nil_values()
  end

  defp tool_call_chunk_block(map) do
    %{
      type: :tool_call_chunk,
      id: ContentBlock.get(map, :id),
      index: ContentBlock.get(map, :index),
      name: ContentBlock.get(map, :name),
      args: ContentBlock.get(map, :args) || ContentBlock.get(map, :arguments),
      tool_call_id: ContentBlock.get(map, :tool_call_id)
    }
    |> MapShape.reject_nil_values()
  end

  defp server_tool_call_block(map) do
    %{
      type: :server_tool_call,
      id: ContentBlock.get(map, :id),
      name: ContentBlock.get(map, :name),
      args: ContentBlock.get(map, :args) || %{},
      raw_provider_block: ContentBlock.get(map, :raw_provider_block)
    }
    |> MapShape.reject_nil_values()
  end

  defp server_tool_call_chunk_block(map) do
    %{
      type: :server_tool_call_chunk,
      id: ContentBlock.get(map, :id),
      index: ContentBlock.get(map, :index),
      name: ContentBlock.get(map, :name),
      args: ContentBlock.get(map, :args)
    }
    |> MapShape.reject_nil_values()
  end

  defp server_tool_result_block(map) do
    %{
      type: :server_tool_result,
      tool_call_id: ContentBlock.get(map, :tool_call_id) || ContentBlock.get(map, :id),
      status: ContentBlock.get(map, :status),
      output: ContentBlock.get(map, :output),
      raw_provider_block: ContentBlock.get(map, :raw_provider_block)
    }
    |> MapShape.reject_nil_values()
  end

  defp text_block_delta_block(map, type) do
    %{
      type: type,
      index: ContentBlock.get(map, :index),
      text: ContentBlock.get(map, :text),
      raw_provider_block: ContentBlock.get(map, :raw_provider_block)
    }
    |> MapShape.reject_nil_values()
  end

  defp json_block(map) do
    %{
      type: :json,
      json: ContentBlock.get(map, :json) || ContentBlock.get(map, :data)
    }
    |> MapShape.reject_nil_values()
  end

  defp guard_content_block(map) do
    %{
      type: :guard_content,
      guard_content: project_guard_content(ContentBlock.get(map, :guard_content))
    }
    |> MapShape.reject_nil_values()
  end

  defp media_block(map) do
    mime_type = ContentBlock.get(map, :mime_type)
    data = ContentBlock.get(map, :data)

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
      id: ContentBlock.get(map, :id),
      refusal: ContentBlock.get(map, :refusal),
      raw_provider_block: ContentBlock.get(map, :raw_provider_block)
    }
    |> MapShape.reject_nil_values()
  end

  defp provider_output_block(map, type) do
    %{
      type: type,
      id: ContentBlock.get(map, :id),
      status: ContentBlock.get(map, :status),
      queries: ContentBlock.get(map, :queries),
      results: ContentBlock.get(map, :results),
      result: ContentBlock.get(map, :result),
      action: ContentBlock.get(map, :action),
      tools: ContentBlock.get(map, :tools),
      execution: ContentBlock.get(map, :execution),
      output: ContentBlock.get(map, :output),
      call_id: ContentBlock.get(map, :call_id),
      name: ContentBlock.get(map, :name),
      raw_provider_block: ContentBlock.get(map, :raw_provider_block) || raw_provider_block(map)
    }
    |> MapShape.reject_nil_values()
  end

  defp provider_image_bytes?(map) do
    image = ContentBlock.get(map, :image)
    source = if is_map(image), do: ContentBlock.get(image, :source), else: nil

    is_map(source) and is_binary(ContentBlock.get(source, :bytes))
  end

  defp provider_image_bytes_block(map) do
    image = ContentBlock.get(map, :image)
    source = ContentBlock.get(image, :source)
    format = ContentBlock.get(image, :format) || "jpeg"

    ContentBlock.image(%{
      data: Base.encode64(ContentBlock.get(source, :bytes)),
      mime_type: "image/#{format}",
      metadata: metadata(map)
    })
  end

  defp raw_provider_block(%{} = map), do: map

  defp thought_signature(map) when is_map(map) do
    ContentBlock.get(map, :thought_signature) ||
      Map.get(map, "thoughtSignature") ||
      Map.get(map, :thoughtSignature) ||
      metadata_thought_signature(metadata(map))
  end

  defp metadata_thought_signature(metadata) when is_map(metadata) do
    ContentBlock.get(metadata, :thought_signature) ||
      Map.get(metadata, "thoughtSignature") ||
      Map.get(metadata, :thoughtSignature)
  end

  defp metadata_thought_signature(_metadata), do: nil

  defp put_metadata_thought_signature(metadata, nil), do: metadata

  defp put_metadata_thought_signature(metadata, signature) when is_binary(signature) and signature != "" do
    Map.put(metadata, :thought_signature, signature)
  end

  defp put_metadata_thought_signature(metadata, _signature), do: metadata

  defp encode_binary_data(data) when is_binary(data), do: Base.encode64(data)
  defp encode_binary_data(data), do: data

  defp project_guard_content(%{} = guard_content) do
    %{
      text: ContentBlock.get(guard_content, :text),
      type: ContentBlock.get(guard_content, :type),
      raw_provider_block: raw_provider_block(guard_content)
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
