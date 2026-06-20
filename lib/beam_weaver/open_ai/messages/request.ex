defmodule BeamWeaver.OpenAI.Messages.Request do
  @moduledoc false

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.OpenAI.Error
  alias BeamWeaver.OpenAI.Messages.Shared
  alias BeamWeaver.Result
  alias BeamWeaver.Tool.Renderer

  @spec to_responses_input([Message.t()]) :: {:ok, [map()]} | {:error, Error.t()}
  def to_responses_input(messages) when is_list(messages) do
    Result.flat_traverse(messages, &to_response_input/1)
  end

  def to_responses_input(_messages) do
    {:error, Error.new(:invalid_messages, "OpenAI input messages must be a list")}
  end

  @spec tool_to_openai(term()) :: map()
  def tool_to_openai(tool), do: Renderer.openai_tool!(tool)

  @spec tools_to_openai([term()]) :: [map()]
  def tools_to_openai(tools) when is_list(tools), do: Enum.map(tools, &tool_to_openai/1)

  @spec structured_output_format(String.t(), map(), keyword()) :: map()
  def structured_output_format(name, schema, opts \\ [])
      when is_binary(name) and is_map(schema) do
    strict = Keyword.get(opts, :strict, true)

    %{
      "type" => "json_schema",
      "name" => name,
      "schema" => response_schema(schema, strict),
      "strict" => strict
    }
  end

  defp response_schema(schema, true), do: Renderer.strict_json_schema(schema, optional: :nullable)
  defp response_schema(schema, _strict), do: Shared.stringify_keys(schema)

  @spec normalize_input_items([map()] | nil) :: {:ok, [map()]} | {:error, Error.t()}
  def normalize_input_items(nil), do: {:ok, []}

  def normalize_input_items(items) when is_list(items) do
    if Enum.all?(items, &is_map/1) do
      {:ok, Enum.map(items, &Shared.stringify_keys/1)}
    else
      {:error, Error.new(:invalid_input_items, "OpenAI input_items must be maps")}
    end
  end

  def normalize_input_items(_items) do
    {:error, Error.new(:invalid_input_items, "OpenAI input_items must be a list")}
  end

  @spec last_after_previous_response([Message.t()]) :: {[Message.t()], String.t() | nil}
  def last_after_previous_response(messages) when is_list(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value({messages, nil}, fn
      {%Message{role: :assistant} = message, index} ->
        case response_id(message) do
          "resp_" <> _rest = id -> {Enum.drop(messages, index + 1), id}
          _missing -> nil
        end

      _other ->
        nil
    end)
  end

  defp response_id(%Message{} = message) do
    Map.get(message.response_metadata || %{}, :id) ||
      Map.get(message.metadata || %{}, :id)
  end

  defp to_response_input(%Message{role: :tool} = message) do
    call_id = message.tool_call_id || message.id

    if is_binary(call_id) and call_id != "" do
      {:ok,
       %{
         "type" => "function_call_output",
         "call_id" => call_id,
         "output" => tool_output(message.content)
       }}
    else
      {:error, Error.new(:invalid_tool_message, "tool messages require a tool_call_id or id")}
    end
  end

  defp to_response_input(%Message{role: :assistant} = message) do
    items = assistant_content_items(message) ++ assistant_tool_call_items(message)

    if items == [] do
      {:ok, %{"type" => "message", "role" => "assistant", "content" => ""}}
    else
      {:ok, items}
    end
  end

  defp to_response_input(%Message{} = message) do
    {:ok,
     %{
       "type" => "message",
       "role" => provider_role(message),
       "content" => content_to_openai(message.content)
     }}
  end

  defp to_response_input(_message) do
    {:error, Error.new(:invalid_message, "expected a BeamWeaver message")}
  end

  defp tool_output(content) when is_binary(content), do: content

  defp tool_output(content) when is_map(content) or is_list(content) do
    case BeamWeaver.JSON.encode(content) do
      {:ok, json} -> json
      {:error, _error} -> inspect(content)
    end
  end

  defp tool_output(content), do: to_string(content)

  defp provider_role(%Message{} = message) do
    message.metadata
    |> Map.get(:openai_role)
    |> Kernel.||(Atom.to_string(message.role))
    |> provider_role_value()
  end

  defp provider_role_value(role) when is_atom(role), do: Atom.to_string(role)
  defp provider_role_value(role), do: to_string(role)

  defp content_to_openai(content) when is_binary(content), do: content

  defp content_to_openai(content) when is_list(content) do
    content
    |> assert_atom_content_blocks!()
    |> Enum.map(&content_block_to_openai/1)
  end

  defp content_block_to_openai(text) when is_binary(text) do
    %{"type" => "input_text", "text" => text}
  end

  defp content_block_to_openai(%{type: :text, text: text}) when is_binary(text) do
    %{"type" => "input_text", "text" => text}
  end

  defp content_block_to_openai(%{type: :plain_text, text: text}) when is_binary(text) do
    %{"type" => "input_text", "text" => text}
  end

  defp content_block_to_openai(%{type: :image, url: url} = block) when is_binary(url) do
    metadata = Map.get(block, :metadata, %{})

    %{"type" => "input_image", "image_url" => url}
    |> Shared.put_optional("detail", Map.get(metadata || %{}, :detail))
  end

  defp content_block_to_openai(%{type: :image_url, image_url: image_url} = block)
       when is_binary(image_url) do
    %{
      "type" => "input_image",
      "image_url" => image_url,
      "detail" => Map.get(block, :detail)
    }
    |> Shared.reject_nil_values()
  end

  defp content_block_to_openai(%{type: :image_url, image_url: image_url} = block) do
    image_url = Shared.stringify_value(image_url)

    %{
      "type" => "input_image",
      "image_url" => image_url["url"] || image_url,
      "detail" => image_url["detail"] || Map.get(block, :detail)
    }
    |> Shared.reject_nil_values()
  end

  defp content_block_to_openai(%{type: :image, base64: data} = block) when is_binary(data) do
    %{
      "type" => "input_image",
      "image_url" =>
        Shared.data_url(
          Map.get(block, :mime_type) || Map.get(block, :format) || "image/png",
          data
        )
    }
  end

  defp content_block_to_openai(%{type: :image, data: data} = block) when is_binary(data) do
    %{
      "type" => "input_image",
      "image_url" => Shared.data_url(Map.get(block, :mime_type) || "image/png", data)
    }
  end

  defp content_block_to_openai(%{type: :image, source: source})
       when is_map(source) do
    case {Map.get(source, :type), Map.get(source, :media_type), Map.get(source, :data)} do
      {:base64, mime_type, data} when is_binary(mime_type) and is_binary(data) ->
        %{"type" => "input_image", "image_url" => Shared.data_url(mime_type, data)}

      {"base64", mime_type, data} when is_binary(mime_type) and is_binary(data) ->
        %{"type" => "input_image", "image_url" => Shared.data_url(mime_type, data)}

      _other ->
        %{"type" => "input_image", "image_url" => nil} |> Shared.reject_nil_values()
    end
  end

  defp content_block_to_openai(%{type: :media, mime_type: mime_type, data: data})
       when is_binary(mime_type) and is_binary(data) do
    %{
      "type" => "input_image",
      "image_url" => Shared.data_url(mime_type, data)
    }
  end

  defp content_block_to_openai(%{type: :file, url: url}) when is_binary(url) do
    %{"type" => "input_file", "file_url" => url}
  end

  defp content_block_to_openai(%{type: :file, file_id: file_id}) when is_binary(file_id) do
    %{"type" => "input_file", "file_id" => file_id}
  end

  defp content_block_to_openai(%{type: :file, base64: data} = block) when is_binary(data) do
    %{
      "type" => "input_file",
      "file_data" => Shared.data_url(Map.get(block, :mime_type) || "application/pdf", data),
      "filename" => Map.get(block, :filename)
    }
    |> Shared.reject_nil_values()
  end

  defp content_block_to_openai(%{type: :file, data: data} = block) when is_binary(data) do
    %{
      "type" => "input_file",
      "file_data" => Shared.data_url(Map.get(block, :mime_type) || "application/pdf", data),
      "filename" => Map.get(block, :filename)
    }
    |> Shared.reject_nil_values()
  end

  defp content_block_to_openai(%{type: :audio, base64: data} = block) when is_binary(data) do
    %{
      "type" => "input_audio",
      "input_audio" => %{
        "data" => data,
        "format" => Shared.audio_format(Map.get(block, :mime_type) || Map.get(block, :format))
      }
    }
  end

  defp content_block_to_openai(%{type: :audio, data: data} = block) when is_binary(data) do
    %{
      "type" => "input_audio",
      "input_audio" => %{
        "data" => data,
        "format" => Shared.audio_format(Map.get(block, :mime_type) || Map.get(block, :format))
      }
    }
  end

  defp content_block_to_openai(%ContentBlock.Unknown{value: value}) when is_map(value) do
    Shared.stringify_keys(value)
  end

  defp content_block_to_openai(block) when is_map(block) do
    BeamWeaver.MapShape.assert_atom_keys!(block)
    Shared.stringify_keys(block)
  end

  defp assistant_content_items(%Message{content: content, id: message_id})
       when is_binary(content) do
    case content do
      "" ->
        []

      text ->
        [
          assistant_message_item(
            [%{"type" => "output_text", "text" => text, "annotations" => []}],
            message_id
          )
        ]
    end
  end

  defp assistant_content_items(%Message{content: content, id: message_id})
       when is_list(content) do
    content
    |> Enum.reduce({[], nil, []}, fn block, state ->
      case assistant_content_event(block, message_id) do
        {:message_part, id, part} -> add_assistant_message_part(state, id, part)
        {:item, item} -> add_assistant_raw_item(state, item)
        :skip -> state
      end
    end)
    |> flush_assistant_message_parts()
  end

  defp assistant_content_event(%{type: type, text: text} = block, message_id)
       when type in [:text, :output_text] and is_binary(text) do
    {:message_part, Map.get(block, :id) || message_id,
     %{
       "type" => "output_text",
       "text" => text,
       "annotations" => Map.get(block, :annotations, [])
     }}
  end

  defp assistant_content_event(%{type: :refusal, refusal: refusal} = block, message_id)
       when is_binary(refusal) do
    {:message_part, Map.get(block, :id) || message_id, %{"type" => "refusal", "refusal" => refusal}}
  end

  defp assistant_content_event(%ContentBlock.Unknown{value: value}, _message_id) when is_map(value) do
    {:item, value |> Shared.stringify_keys() |> drop_internal_provider_fields()}
  end

  defp assistant_content_event(%{type: type} = block, _message_id)
       when type in [:function_call, :tool_call, :tool_use] do
    BeamWeaver.MapShape.assert_atom_keys!(block)
    {:item, block |> Shared.stringify_keys() |> normalize_function_call_item()}
  end

  defp assistant_content_event(%{type: type} = block, _message_id) do
    BeamWeaver.MapShape.assert_atom_keys!(block)
    type = provider_type(type)

    if Shared.output_block_type?(type) do
      {:item, sanitize_output_item(block)}
    else
      :skip
    end
  end

  defp assistant_content_event(_block, _message_id), do: :skip

  defp add_assistant_message_part({items, nil, []}, id, part), do: {items, id, [part]}
  defp add_assistant_message_part({items, id, parts}, id, part), do: {items, id, [part | parts]}

  defp add_assistant_message_part({items, id, parts}, next_id, part) do
    {[assistant_message_item(Enum.reverse(parts), id) | items], next_id, [part]}
  end

  defp add_assistant_raw_item({items, nil, []}, item), do: {[item | items], nil, []}

  defp add_assistant_raw_item({items, id, parts}, item) do
    {[item, assistant_message_item(Enum.reverse(parts), id) | items], nil, []}
  end

  defp flush_assistant_message_parts({items, nil, []}), do: Enum.reverse(items)

  defp flush_assistant_message_parts({items, id, parts}) do
    Enum.reverse([assistant_message_item(Enum.reverse(parts), id) | items])
  end

  defp assistant_message_item(parts, id) do
    %{"type" => "message", "role" => "assistant", "content" => parts}
    |> Shared.put_optional("id", id)
  end

  defp assistant_tool_call_items(%Message{content: content, tool_calls: tool_calls})
       when is_list(tool_calls) do
    if assistant_content_has_function_call?(content) do
      []
    else
      Enum.map(tool_calls, &tool_call_to_function_call_item/1)
    end
  end

  defp assistant_content_has_function_call?(content) when is_list(content) do
    Enum.any?(content, fn
      %{type: type} when type in [:function_call, "function_call", :tool_call, "tool_call", :tool_use, "tool_use"] ->
        true

      _block ->
        false
    end)
  end

  defp assistant_content_has_function_call?(_content), do: false

  defp tool_call_to_function_call_item(tool_call) when is_map(tool_call) do
    %{
      "type" => "function_call",
      "id" => Map.get(tool_call, :provider_id) || Map.get(tool_call, :id),
      "call_id" => Map.get(tool_call, :call_id) || Map.get(tool_call, :id),
      "name" => Map.get(tool_call, :name),
      "arguments" => function_call_arguments(tool_call)
    }
    |> Shared.reject_nil_values()
  end

  defp function_call_arguments(%{arguments: arguments}) when is_binary(arguments),
    do: arguments

  defp function_call_arguments(%{arguments: arguments}),
    do: BeamWeaver.JSON.encode!(arguments)

  defp function_call_arguments(%{args: args}), do: BeamWeaver.JSON.encode!(args)
  defp function_call_arguments(_call), do: "{}"

  defp normalize_function_call_item(item) do
    item
    |> Map.update("type", "function_call", fn
      "tool_call" -> "function_call"
      "tool_use" -> "function_call"
      type -> type
    end)
    |> Map.update("id", item["provider_id"] || item["id"], fn id -> item["provider_id"] || id end)
    |> Map.put_new("arguments", item["args"] || item["input"])
    |> Map.take(["type", "id", "call_id", "name", "arguments"])
    |> Map.update("arguments", "{}", fn
      arguments when is_binary(arguments) -> arguments
      arguments -> BeamWeaver.JSON.encode!(arguments)
    end)
    |> Shared.reject_nil_values()
  end

  defp provider_type(type) when is_atom(type), do: Atom.to_string(type)
  defp provider_type(type), do: type

  defp sanitize_output_item(%{type: :reasoning} = block) do
    block
    |> Shared.stringify_keys()
    |> Map.take(["type", "id", "summary", "status", "encrypted_content"])
    |> Shared.reject_nil_values()
  end

  defp sanitize_output_item(block) when is_map(block) do
    block
    |> Shared.stringify_keys()
    |> drop_internal_provider_fields()
  end

  defp drop_internal_provider_fields(value) when is_list(value),
    do: Enum.map(value, &drop_internal_provider_fields/1)

  defp drop_internal_provider_fields(value) when is_map(value) do
    value
    |> Map.drop(["raw_provider_block", "provider_id", "__struct__"])
    |> Map.new(fn {key, nested} -> {key, drop_internal_provider_fields(nested)} end)
  end

  defp drop_internal_provider_fields(value), do: value

  defp assert_atom_content_blocks!(content) do
    Enum.each(content, fn
      block when is_struct(block) -> BeamWeaver.MapShape.assert_atom_keys!(Map.from_struct(block))
      block when is_map(block) -> BeamWeaver.MapShape.assert_atom_keys!(block)
      _block -> :ok
    end)

    content
  end
end
