defmodule BeamWeaver.OpenAI.ChatCompletions.Messages.Request do
  @moduledoc false

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.OpenAI.Error
  alias BeamWeaver.OpenAI.MessageParts
  alias BeamWeaver.Result
  alias BeamWeaver.Tool.Renderer

  def to_openai_messages(messages) when is_list(messages) do
    Result.traverse(messages, &to_openai_message/1)
  end

  def to_openai_messages(_messages) do
    {:error, Error.new(:invalid_messages, "OpenAI chat-completions messages must be a list")}
  end

  def structured_output_format(name, schema, opts \\ [])
      when is_binary(name) and is_map(schema) do
    %{
      "type" => "json_schema",
      "json_schema" => %{
        "name" => name,
        "schema" => MessageParts.stringify_keys(schema),
        "strict" => Keyword.get(opts, :strict, true)
      }
    }
  end

  def tools_to_openai(tools) when is_list(tools), do: Enum.map(tools, &tool_to_openai/1)

  def tool_to_openai(%{__struct__: _module} = tool) do
    case Renderer.openai_function(tool) do
      {:ok, function} -> %{"type" => "function", "function" => function}
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  def tool_to_openai(tool) when is_map(tool) do
    tool = MessageParts.stringify_keys(tool)

    if Map.has_key?(tool, "function") do
      tool
    else
      %{"type" => "function", "function" => Map.delete(tool, "type")}
    end
  end

  def tool_to_openai(tool) do
    case Renderer.openai_function(tool) do
      {:ok, function} -> %{"type" => "function", "function" => function}
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp to_openai_message(%Message{role: :tool} = message) do
    call_id = message.tool_call_id || message.id

    if is_binary(call_id) and call_id != "" do
      {:ok,
       %{
         "role" => "tool",
         "tool_call_id" => call_id,
         "content" => Message.text(message)
       }}
    else
      {:error, Error.new(:invalid_tool_message, "tool messages require a tool_call_id or id")}
    end
  end

  defp to_openai_message(%Message{role: :assistant, metadata: metadata} = message)
       when is_map(metadata) do
    if provider_role(message) == "function" do
      {:ok,
       %{
         "role" => "function",
         "content" => content_to_openai(message.content)
       }
       |> put_optional("name", message.name)}
    else
      to_assistant_openai_message(message)
    end
  end

  defp to_openai_message(%Message{role: :assistant} = message) do
    to_assistant_openai_message(message)
  end

  defp to_openai_message(%Message{} = message) do
    {:ok,
     %{
       "role" => provider_role(message),
       "content" => content_to_openai(message.content)
     }
     |> put_optional("name", message.name)}
  end

  defp to_openai_message(_message),
    do: {:error, Error.new(:invalid_message, "expected a BeamWeaver message")}

  defp to_assistant_openai_message(%Message{} = message) do
    base =
      %{
        "role" => "assistant",
        "content" => assistant_content(message)
      }
      |> put_optional("name", message.name)
      |> put_optional("tool_calls", assistant_tool_calls(message))

    {:ok, base}
  end

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
    |> Enum.map(&content_part/1)
  end

  defp content_to_openai(content), do: to_string(content)

  defp content_part(text) when is_binary(text),
    do: %{"type" => "text", "text" => text}

  defp content_part(%{type: :text, text: text}) when is_binary(text),
    do: %{"type" => "text", "text" => text}

  defp content_part(%{type: :plain_text, text: text}) when is_binary(text),
    do: %{"type" => "text", "text" => text}

  defp content_part(%{type: :image, url: url} = block) when is_binary(url) do
    image_url =
      %{"url" => url}
      |> put_optional("detail", Map.get(Map.get(block, :metadata, %{}) || %{}, :detail))

    %{"type" => "image_url", "image_url" => image_url}
  end

  defp content_part(%{type: :image_url, image_url: image_url}) do
    %{"type" => "image_url", "image_url" => MessageParts.stringify_value(image_url)}
  end

  defp content_part(%{type: :image, base64: data} = block) when is_binary(data) do
    %{
      "type" => "image_url",
      "image_url" => %{
        "url" => MessageParts.data_url(Map.get(block, :mime_type) || "image/png", data)
      }
    }
  end

  defp content_part(%{type: :image, data: data} = block) when is_binary(data) do
    %{
      "type" => "image_url",
      "image_url" => %{
        "url" => MessageParts.data_url(Map.get(block, :mime_type) || "image/png", data)
      }
    }
  end

  defp content_part(%{type: :audio, base64: data} = block) when is_binary(data) do
    %{
      "type" => "input_audio",
      "input_audio" => %{
        "data" => data,
        "format" => MessageParts.audio_format(Map.get(block, :mime_type) || Map.get(block, :format))
      }
    }
  end

  defp content_part(%{type: :audio, data: data} = block) when is_binary(data) do
    %{
      "type" => "input_audio",
      "input_audio" => %{
        "data" => data,
        "format" => MessageParts.audio_format(Map.get(block, :mime_type) || Map.get(block, :format))
      }
    }
  end

  defp content_part(%{type: :file, base64: data} = block) when is_binary(data) do
    %{
      "type" => "file",
      "file" =>
        %{
          "file_data" => MessageParts.data_url(Map.get(block, :mime_type) || "application/pdf", data),
          "filename" => Map.get(block, :filename)
        }
        |> MessageParts.reject_nil_values()
    }
  end

  defp content_part(%{type: :file, data: data} = block) when is_binary(data) do
    %{
      "type" => "file",
      "file" =>
        %{
          "file_data" => MessageParts.data_url(Map.get(block, :mime_type) || "application/pdf", data),
          "filename" => Map.get(block, :filename)
        }
        |> MessageParts.reject_nil_values()
    }
  end

  defp content_part(%{type: :file, url: url}) when is_binary(url),
    do: %{"type" => "file", "file" => %{"file_url" => url}}

  defp content_part(%{type: :file, file_id: file_id}) when is_binary(file_id),
    do: %{"type" => "file", "file" => %{"file_id" => file_id}}

  defp content_part(%ContentBlock.Unknown{value: value}) when is_map(value) do
    MessageParts.stringify_keys(value)
  end

  defp content_part(block) when is_map(block) do
    BeamWeaver.MapShape.assert_atom_keys!(block)
    MessageParts.stringify_keys(block)
  end

  defp assistant_content(%Message{content: content}) when is_binary(content), do: content

  defp assistant_content(%Message{content: content}) when is_list(content),
    do: content_to_openai(content)

  defp assistant_tool_calls(%Message{} = message) do
    calls =
      (message.tool_calls || []) ++
        (Map.get(message.metadata || %{}, :invalid_tool_calls) || [])

    case calls do
      [] -> nil
      calls -> Enum.map(calls, &assistant_tool_call/1)
    end
  end

  defp assistant_tool_call(tool_call) do
    %{
      "id" => Map.get(tool_call, :id) || Map.get(tool_call, :call_id),
      "type" => "function",
      "function" => %{
        "name" => Map.get(tool_call, :name),
        "arguments" => tool_call_arguments(tool_call)
      }
    }
    |> MessageParts.reject_nil_values()
  end

  defp tool_call_arguments(%{type: :invalid_tool_call, args: args})
       when is_binary(args),
       do: args

  defp tool_call_arguments(%{arguments: args}) when is_binary(args), do: args
  defp tool_call_arguments(%{arguments: args}), do: BeamWeaver.JSON.encode!(args)
  defp tool_call_arguments(%{args: args}) when is_binary(args), do: args
  defp tool_call_arguments(%{args: args}), do: BeamWeaver.JSON.encode!(args)
  defp tool_call_arguments(_call), do: "{}"

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, _key, []), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp assert_atom_content_blocks!(content) do
    Enum.each(content, fn
      block when is_struct(block) -> BeamWeaver.MapShape.assert_atom_keys!(Map.from_struct(block))
      block when is_map(block) -> BeamWeaver.MapShape.assert_atom_keys!(block)
      _block -> :ok
    end)

    content
  end
end
