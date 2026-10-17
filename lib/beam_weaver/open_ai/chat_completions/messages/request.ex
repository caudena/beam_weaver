defmodule BeamWeaver.OpenAI.ChatCompletions.Messages.Request do
  @moduledoc false

  import BeamWeaver.MapShape, only: [put_optional: 3]
  import BeamWeaver.OpenAI.MessageParts, only: [block_option: 2, provider_role: 1, put_prompt_cache_breakpoint: 2]

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Error
  alias BeamWeaver.OpenAI.MessageParts
  alias BeamWeaver.OpenAI.Messages.Request, as: Responses
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
    strict = Keyword.get(opts, :strict, true)

    %{
      "type" => "json_schema",
      "json_schema" => %{
        "name" => name,
        "schema" => Responses.response_schema(schema, strict),
        "strict" => strict
      }
    }
  end

  def tools_to_openai(tools) when is_list(tools), do: Enum.map(tools, &tool_to_openai/1)

  def tool_to_openai(tool) do
    case render_tool(tool) do
      {:ok, rendered} -> rendered
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @doc false
  @spec render_tools([term()]) :: {:ok, [map()]} | {:error, Error.t()}
  def render_tools(tools) when is_list(tools), do: Result.traverse(tools, &render_tool/1)

  # Chat Completions takes function tools only: a built-in tool of the
  # Responses API, such as web search, is an error rather than an empty
  # function.
  @doc false
  @spec render_tool(term()) :: {:ok, map()} | {:error, Error.t()}
  def render_tool(tool) when is_map(tool) and not is_struct(tool) do
    tool = MessageParts.stringify_keys(tool)

    cond do
      Map.has_key?(tool, "function") ->
        {:ok, tool}

      tool["type"] in [nil, "function"] ->
        {:ok, %{"type" => "function", "function" => Map.delete(tool, "type")}}

      true ->
        {:error,
         Error.new(
           :unsupported_feature,
           "Chat Completions takes function tools only; #{inspect(tool["type"])} is a Responses API tool",
           %{api: :chat_completions, tool_type: tool["type"], alternative_api: :responses}
         )}
    end
  end

  def render_tool(tool) do
    with {:ok, function} <- Renderer.openai_function(tool) do
      {:ok, %{"type" => "function", "function" => function}}
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
      with {:ok, content} <- content_to_openai(message.content) do
        {:ok, %{"role" => "function", "content" => content} |> put_optional("name", message.name)}
      end
    else
      to_assistant_openai_message(message)
    end
  end

  defp to_openai_message(%Message{role: :assistant} = message) do
    to_assistant_openai_message(message)
  end

  defp to_openai_message(%Message{} = message) do
    with :ok <- check_additional_tools(message.content),
         {:ok, content} <- content_to_openai(message.content) do
      {:ok, %{"role" => provider_role(message), "content" => content} |> put_optional("name", message.name)}
    end
  end

  defp to_openai_message(_message),
    do: {:error, Error.new(:invalid_message, "expected a BeamWeaver message")}

  # Tools added partway through are an input item of the Responses API only.
  defp check_additional_tools(content) when is_list(content) do
    if Enum.any?(content, &(block_type(&1) == "additional_tools")) do
      {:error,
       Error.new(:unsupported_feature, "additional_tools needs the Responses API", %{
         api: :chat_completions,
         feature: :additional_tools,
         alternative_api: :responses
       })}
    else
      :ok
    end
  end

  defp check_additional_tools(_content), do: :ok

  defp to_assistant_openai_message(%Message{} = message) do
    with {:ok, content} <- message.content |> assistant_content() |> content_to_openai() do
      {:ok,
       %{"role" => "assistant", "content" => content}
       |> put_optional("name", message.name)
       |> put_optional("tool_calls", assistant_tool_calls(message))}
    end
  end

  # Chat Completions takes an assistant's text, refusals and tool calls (in
  # `tool_calls`). The reasoning, tool-call and provider tool blocks of a
  # reply, such as an Anthropic or Responses API reply after a model
  # fallback, have no part here and are left out.
  @reply_block_types ~w(tool_call tool_call_chunk tool_use function_call input_json_delta
                        server_tool_call server_tool_call_chunk server_tool_result)

  defp assistant_content(content) when is_list(content) do
    case Enum.reject(content, &reply_block?/1) do
      [] -> ""
      content -> content
    end
  end

  defp assistant_content(content), do: content

  defp reply_block?(block) do
    type = block_type(block)
    ContentBlock.reasoning?(block) or type in @reply_block_types or MessageParts.output_block_type?(type)
  end

  defp block_type(%ContentBlock.Unknown{provider_type: type}), do: to_string(type)
  defp block_type(%{type: type}) when is_atom(type) or is_binary(type), do: to_string(type)
  defp block_type(_block), do: nil

  defp content_to_openai(content) when is_binary(content), do: {:ok, content}

  defp content_to_openai(content) when is_list(content) do
    content
    |> BeamWeaver.MapShape.assert_atom_keys_in!()
    |> Result.traverse(fn block ->
      case content_part(block) do
        {:error, %Error{}} = error -> error
        part -> {:ok, part}
      end
    end)
  end

  defp content_to_openai(content), do: {:ok, to_string(content)}

  defp content_part(text) when is_binary(text),
    do: %{"type" => "text", "text" => text}

  defp content_part(%{type: type, text: text} = block) when type in [:text, :plain_text] and is_binary(text) do
    %{"type" => "text", "text" => text}
    |> put_prompt_cache_breakpoint(block)
  end

  defp content_part(%{type: :image, url: url} = block) when is_binary(url), do: image_part(url, block)

  defp content_part(%{type: :image_url, image_url: image_url} = block) do
    %{"type" => "image_url", "image_url" => MessageParts.stringify_value(image_url)}
    |> put_prompt_cache_breakpoint(block)
  end

  defp content_part(%{type: type, base64: data} = block) when type in [:image, :audio, :file] and is_binary(data),
    do: inline_part(type, data, block)

  defp content_part(%{type: type, data: data} = block) when type in [:image, :audio, :file] and is_binary(data),
    do: inline_part(type, data, block)

  defp content_part(%{type: :file, url: url} = block) when is_binary(url) do
    %{"type" => "file", "file" => %{"file_url" => url}}
    |> put_prompt_cache_breakpoint(block)
  end

  defp content_part(%{type: :file, file_id: file_id} = block) when is_binary(file_id) do
    %{"type" => "file", "file" => %{"file_id" => file_id}}
    |> put_prompt_cache_breakpoint(block)
  end

  defp content_part(%{type: :refusal, refusal: refusal} = block) when is_binary(refusal) do
    %{"type" => "refusal", "refusal" => refusal}
    |> put_prompt_cache_breakpoint(block)
  end

  defp content_part(%ContentBlock.Unknown{value: value}) when is_map(value) do
    MessageParts.stringify_keys(value)
  end

  # A content block Chat Completions has no part for, such as video, or one
  # without the data its part needs, such as audio given by URL.
  defp content_part(%{__struct__: module} = block) do
    type = Map.get(block, :type, module)

    {:error,
     Error.new(:unsupported_feature, "Chat Completions input does not take this #{inspect(type)} block", %{
       api: :chat_completions,
       feature: type
     })}
  end

  defp content_part(block) when is_map(block) do
    BeamWeaver.MapShape.assert_atom_keys!(block)
    MessageParts.stringify_keys(block)
  end

  defp inline_part(:image, data, block),
    do: image_part(MessageParts.data_url(Map.get(block, :mime_type) || "image/png", data), block)

  defp inline_part(:audio, data, block) do
    %{
      "type" => "input_audio",
      "input_audio" => %{
        "data" => data,
        "format" => MessageParts.audio_format(Map.get(block, :mime_type) || Map.get(block, :format))
      }
    }
    |> put_prompt_cache_breakpoint(block)
  end

  defp inline_part(:file, data, block) do
    file =
      MessageParts.reject_nil_values(%{
        "file_data" => MessageParts.data_url(Map.get(block, :mime_type) || "application/pdf", data),
        "filename" => Map.get(block, :filename)
      })

    put_prompt_cache_breakpoint(%{"type" => "file", "file" => file}, block)
  end

  defp image_part(url, block) do
    image_url = put_optional(%{"url" => url}, "detail", MessageParts.stringify_value(block_option(block, :detail)))
    put_prompt_cache_breakpoint(%{"type" => "image_url", "image_url" => image_url}, block)
  end

  defp assistant_tool_calls(%Message{} = message) do
    calls =
      (message.tool_calls || []) ++
        (Map.get(message.metadata || %{}, :invalid_tool_calls) || [])

    case calls do
      [] -> nil
      calls -> Enum.map(calls, &assistant_tool_call/1)
    end
  end

  # The call's id is the one its tool result answers (`call_id`, as the tool
  # node reads it), not the id of the provider item that carried it, such as
  # a Responses `function_call` item's.
  defp assistant_tool_call(tool_call) do
    %{
      "id" => Map.get(tool_call, :call_id) || Map.get(tool_call, :id) || Map.get(tool_call, :provider_id),
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
end
