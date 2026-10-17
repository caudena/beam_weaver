defmodule BeamWeaver.OpenAI.Messages.Request do
  @moduledoc false

  import BeamWeaver.OpenAI.MessageParts, only: [block_option: 2, provider_role: 1, put_prompt_cache_breakpoint: 2]

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Error
  alias BeamWeaver.OpenAI.MessageParts
  alias BeamWeaver.Provider.ChatCompletionsWire
  alias BeamWeaver.Result
  alias BeamWeaver.Tool.Renderer

  # Providers whose Responses API replies this input takes back as items.
  @responses_providers ["openai", "xai", "deepseek"]

  # Blocks that go as input items of their own, just before the rest of their
  # message: a `configuration_update`, such as a new reasoning effort from this
  # message on, the items that answer a provider tool, and `additional_tools`,
  # tools added partway through, which only a system message carries (OpenAI
  # takes it only with the developer role).
  @input_item_types ~w(configuration_update mcp_approval_response tool_search_output apply_patch_call_output
                       additional_tools)

  @spec to_responses_input([Message.t()], keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def to_responses_input(messages, opts \\ [])

  def to_responses_input(messages, opts) when is_list(messages) and is_list(opts) do
    Result.flat_traverse(messages, &to_response_input(&1, opts))
  end

  def to_responses_input(_messages, _opts) do
    {:error, Error.new(:invalid_messages, "OpenAI input messages must be a list")}
  end

  @spec tool_to_openai(term()) :: map()
  def tool_to_openai(tool), do: Renderer.openai_tool!(tool)

  @spec tools_to_openai([term()]) :: [map()]
  def tools_to_openai(tools) when is_list(tools), do: Enum.map(tools, &tool_to_openai/1)

  @spec structured_output_format(String.t(), map(), keyword()) :: map()
  def structured_output_format(name, schema, opts \\ [])
      when is_binary(name) and is_map(schema) do
    # nil means unspecified, and the default is strict; only an explicit false opts out.
    strict = Keyword.get(opts, :strict) != false

    %{
      "type" => "json_schema",
      "name" => name,
      "schema" => response_schema(schema, strict),
      "strict" => strict
    }
  end

  def response_schema(schema, true), do: Renderer.strict_json_schema(schema, optional: :nullable)
  def response_schema(schema, _strict), do: MessageParts.stringify_keys(schema)

  @spec normalize_input_items([map()] | nil) :: {:ok, [map()]} | {:error, Error.t()}
  def normalize_input_items(nil), do: {:ok, []}

  def normalize_input_items(items) when is_list(items) do
    if Enum.all?(items, &is_map/1) do
      {:ok, Enum.map(items, &MessageParts.stringify_keys/1)}
    else
      {:error, Error.new(:invalid_input_items, "OpenAI input_items must be maps")}
    end
  end

  def normalize_input_items(_items) do
    {:error, Error.new(:invalid_input_items, "OpenAI input_items must be a list")}
  end

  # The messages after the last assistant reply that `id_of` returns an id
  # for, and that id. `id_of` recognizes the replies a provider can continue
  # with `previous_response_id`, so a reply from another provider (after a
  # model fallback, say) is sent as a message instead.
  @spec last_after_previous_response([Message.t()], (Message.t() -> String.t() | nil)) ::
          {[Message.t()], String.t() | nil}
  def last_after_previous_response(messages, id_of \\ &response_id/1)
      when is_list(messages) and is_function(id_of, 1) do
    messages
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value({messages, nil}, fn
      {%Message{role: :assistant} = message, index} ->
        case id_of.(message) do
          id when is_binary(id) -> {Enum.drop(messages, index + 1), id}
          _missing -> nil
        end

      _other ->
        nil
    end)
  end

  # The id of a reply OpenAI's Responses API stored. Its ids start with
  # `resp_`, as do those of other Responses APIs (DeepSeek's, say), so a reply
  # from another provider gets nil. A reply made with `store: false` isn't
  # kept, so it can't be continued.
  @spec response_id(Message.t()) :: String.t() | nil
  def response_id(%Message{role: :assistant, response_metadata: %{model_provider: "openai"} = metadata} = message) do
    case Map.get(metadata, :id) || Map.get(message.metadata || %{}, :id) do
      "resp_" <> _rest = id -> if stored?(metadata), do: id
      _other -> nil
    end
  end

  def response_id(_message), do: nil

  def stored?(%{raw_provider_response: %{"store" => false}}), do: false
  def stored?(_metadata), do: true

  defp to_response_input(%Message{role: :tool} = message, _opts) do
    call_id = message.tool_call_id || message.id

    if is_binary(call_id) and call_id != "" do
      with {:ok, output} <- tool_output(message.content) do
        {:ok,
         %{
           "type" => "function_call_output",
           "call_id" => call_id,
           "output" => output
         }
         |> MessageParts.put_optional("name", message.name)
         |> MessageParts.put_optional("namespace", ChatCompletionsWire.metadata_value(message.metadata, :namespace))}
      end
    else
      {:error, Error.new(:invalid_tool_message, "tool messages require a tool_call_id or id")}
    end
  end

  defp to_response_input(
         %Message{
           role: :assistant,
           response_metadata: %{provider_replay: %{provider: provider, content: [_ | _] = content}}
         } = message,
         opts
       )
       when provider in @responses_providers do
    native_items =
      Enum.flat_map(content, fn item ->
        case sanitize_store_replay_item(item, opts) do
          {:item, item} -> [item]
          :skip -> []
        end
      end)

    present_calls =
      native_items
      |> Enum.filter(&(&1["type"] == "function_call"))
      |> MapSet.new(& &1["call_id"])

    missing_calls =
      message.tool_calls
      |> Enum.reject(&MapSet.member?(present_calls, Map.get(&1, :call_id) || Map.get(&1, :id)))
      |> Enum.map(&tool_call_to_function_call_item(&1, opts))

    {:ok, native_items ++ missing_calls}
  end

  defp to_response_input(%Message{role: :assistant} = message, opts) do
    items =
      if responses_reply?(message),
        do: assistant_content_items(message, opts) ++ assistant_tool_call_items(message, opts),
        else: portable_assistant_items(message, opts)

    if items == [] do
      {:ok, %{"type" => "message", "role" => "assistant", "content" => ""}}
    else
      {:ok, items}
    end
  end

  defp to_response_input(%Message{content: content} = message, _opts) when is_list(content) do
    {items, content} = Enum.split_with(content, &(input_item_type(&1) in @input_item_types))

    with :ok <- check_additional_tools(message, items),
         {:ok, content} <- content_to_openai(content) do
      {:ok, Enum.map(items, &input_item/1) ++ message_items(message, content, items)}
    end
  end

  defp to_response_input(%Message{} = message, _opts) do
    with {:ok, content} <- content_to_openai(message.content) do
      {:ok, message_item(message, content)}
    end
  end

  defp to_response_input(_message, _opts) do
    {:error, Error.new(:invalid_message, "expected a BeamWeaver message")}
  end

  # A message whose blocks all went as items of their own adds no message.
  defp message_items(_message, [], [_ | _]), do: []
  defp message_items(message, content, _items), do: [message_item(message, content)]

  defp message_item(message, content),
    do: %{"type" => "message", "role" => provider_role(message), "content" => content}

  defp check_additional_tools(%Message{role: :system}, _items), do: :ok

  defp check_additional_tools(%Message{role: role}, items) do
    if Enum.any?(items, &(input_item_type(&1) == "additional_tools")) do
      {:error,
       Error.new(
         :invalid_request,
         "additional_tools goes on a system message: OpenAI takes it only with the developer role",
         %{
           api: :responses,
           role: role
         }
       )}
    else
      :ok
    end
  end

  defp input_item_type(%ContentBlock.Unknown{provider_type: type}) when not is_nil(type), do: to_string(type)
  defp input_item_type(%{__struct__: _module}), do: nil
  defp input_item_type(%{type: type}) when is_atom(type) or is_binary(type), do: to_string(type)
  defp input_item_type(_block), do: nil

  defp input_item(%ContentBlock.Unknown{value: value}), do: MessageParts.stringify_keys(value)
  defp input_item(block), do: MessageParts.stringify_keys(block)

  # Output items, their ids and reasoning belong to the Responses API that
  # made them. A reply from another provider or API, such as an Anthropic or
  # Chat Completions reply after a model fallback, has none of them: it goes
  # as its text and its tool calls. A message built by hand counts as a
  # Responses reply.
  defp responses_reply?(%Message{response_metadata: %{model_provider: provider} = metadata})
       when is_binary(provider),
       do: provider in @responses_providers and is_list(metadata[:output])

  defp responses_reply?(%Message{response_metadata: %{provider_replay: %{provider: provider}}}),
    do: provider in @responses_providers

  defp responses_reply?(_message), do: true

  # The id of an assistant message item: the API's own (`msg_...`). A message
  # keeps the response's id, and a thread gives a message it didn't get from
  # the API an id of its own; the API refuses both as an item id.
  defp message_item_id("msg_" <> _rest = id), do: id
  defp message_item_id(_id), do: nil

  defp portable_assistant_items(%Message{content: content, tool_calls: tool_calls} = assistant, opts) do
    parts =
      content
      |> List.wrap()
      |> Enum.flat_map(fn
        text when is_binary(text) and text != "" ->
          [%{"type" => "output_text", "text" => text, "annotations" => []}]

        %{type: type, text: text} when type in [:text, :output_text] and is_binary(text) and text != "" ->
          [%{"type" => "output_text", "text" => text, "annotations" => []}]

        %{type: :refusal, refusal: refusal} when is_binary(refusal) and refusal != "" ->
          [%{"type" => "refusal", "refusal" => refusal}]

        _block ->
          []
      end)

    assistant_message(parts) ++
      Enum.map(tool_calls, &(&1 |> tool_call_to_function_call_item(opts) |> Map.delete("id"))) ++
      invalid_call_items(assistant, opts)
  end

  defp assistant_message([]), do: []
  defp assistant_message(parts), do: [%{"type" => "message", "role" => "assistant", "content" => parts}]

  # Invalid calls, whose arguments came back malformed, go back too, without
  # an id the API didn't issue: the agent answers each with an error output,
  # which needs its call. A reply the API made keeps them in its content.
  defp invalid_call_items(%Message{metadata: %{invalid_tool_calls: calls}}, opts) when is_list(calls) do
    for call <- calls, is_map(call), do: call |> tool_call_to_function_call_item(opts) |> Map.delete("id")
  end

  defp invalid_call_items(_message, _opts), do: []

  defp tool_output(content) when is_list(content) do
    if portable_tool_output?(content),
      do: Result.traverse(content, &content_part/1),
      else: {:ok, ChatCompletionsWire.tool_output(content)}
  end

  defp tool_output(content), do: {:ok, ChatCompletionsWire.tool_output(content)}

  # Responses accepts an array of input text/image/file parts as a function
  # output. Keep ordinary JSON lists encoded as JSON; only the portable closed
  # content-block subset is lowered as multimodal output.
  defp portable_tool_output?([]), do: false

  defp portable_tool_output?(blocks) do
    Enum.all?(blocks, fn
      text when is_binary(text) -> true
      %{type: type} when type in [:text, :plain_text, :image, :image_url, :file] -> true
      _other -> false
    end)
  end

  defp content_to_openai(content) when is_binary(content), do: {:ok, content}

  defp content_to_openai(content) when is_list(content) do
    content
    |> BeamWeaver.MapShape.assert_atom_keys_in!()
    |> Result.traverse(&content_part/1)
  end

  defp content_part(block) do
    case content_block_to_openai(block) do
      {:error, %Error{}} = error -> error
      part -> {:ok, part}
    end
  end

  defp content_block_to_openai(text) when is_binary(text) do
    %{"type" => "input_text", "text" => text}
  end

  defp content_block_to_openai(%{type: type, text: text} = block)
       when type in [:text, :plain_text] and is_binary(text) do
    %{"type" => "input_text", "text" => text}
    |> put_prompt_cache_breakpoint(block)
  end

  defp content_block_to_openai(%{type: :image, url: url} = block) when is_binary(url), do: image_part(url, block)

  defp content_block_to_openai(%{type: :image, file_id: file_id} = block) when is_binary(file_id) do
    %{"type" => "input_image", "file_id" => file_id}
    |> put_input_detail(block)
    |> put_prompt_cache_breakpoint(block)
  end

  defp content_block_to_openai(%{type: :image_url, image_url: image_url} = block)
       when is_binary(image_url) do
    %{
      "type" => "input_image",
      "image_url" => image_url,
      "detail" => block_option(block, :detail)
    }
    |> MessageParts.reject_nil_values()
    |> put_prompt_cache_breakpoint(block)
  end

  defp content_block_to_openai(%{type: :image_url, image_url: image_url} = block) do
    image_url = MessageParts.stringify_value(image_url)

    %{
      "type" => "input_image",
      "image_url" => image_url["url"] || image_url,
      "detail" => image_url["detail"] || block_option(block, :detail)
    }
    |> MessageParts.reject_nil_values()
    |> put_prompt_cache_breakpoint(block)
  end

  defp content_block_to_openai(%{type: :image, base64: data} = block) when is_binary(data),
    do:
      image_part(
        MessageParts.data_url(Map.get(block, :mime_type) || Map.get(block, :format) || "image/png", data),
        block
      )

  defp content_block_to_openai(%{type: :image, data: data} = block) when is_binary(data),
    do: image_part(MessageParts.data_url(Map.get(block, :mime_type) || "image/png", data), block)

  defp content_block_to_openai(%{type: :image, source: source} = block) when is_map(source) do
    case {Map.get(source, :type), Map.get(source, :media_type), Map.get(source, :data)} do
      {type, mime_type, data} when type in [:base64, "base64"] and is_binary(mime_type) and is_binary(data) ->
        image_part(MessageParts.data_url(mime_type, data), block)

      _other ->
        image_part(nil, block)
    end
  end

  defp content_block_to_openai(%{type: :media, mime_type: mime_type, data: data} = block)
       when is_binary(mime_type) and is_binary(data),
       do: image_part(MessageParts.data_url(mime_type, data), block)

  defp content_block_to_openai(%{type: :file, url: url} = block) when is_binary(url) do
    %{"type" => "input_file", "file_url" => url}
    |> put_input_detail(block)
    |> put_prompt_cache_breakpoint(block)
  end

  defp content_block_to_openai(%{type: :file, file_id: file_id} = block)
       when is_binary(file_id) do
    %{"type" => "input_file", "file_id" => file_id}
    |> put_input_detail(block)
    |> put_prompt_cache_breakpoint(block)
  end

  defp content_block_to_openai(%{type: type, base64: data} = block) when type in [:file, :audio] and is_binary(data),
    do: inline_part(type, data, block)

  defp content_block_to_openai(%{type: type, data: data} = block) when type in [:file, :audio] and is_binary(data),
    do: inline_part(type, data, block)

  defp content_block_to_openai(%ContentBlock.Unknown{value: value}) when is_map(value) do
    MessageParts.stringify_keys(value)
  end

  # A content block the Responses API has no input part for, such as video,
  # or one without data the part needs.
  defp content_block_to_openai(%{__struct__: _module, type: type}) do
    {:error,
     Error.new(:unsupported_feature, "Responses API input does not take this #{inspect(type)} block", %{
       api: :responses,
       feature: type
     })}
  end

  defp content_block_to_openai(block) when is_map(block) do
    BeamWeaver.MapShape.assert_atom_keys!(block)
    MessageParts.stringify_keys(block)
  end

  defp put_input_detail(part, block) do
    MessageParts.put_optional(part, "detail", block_option(block, :detail) |> MessageParts.stringify_value())
  end

  defp image_part(url, block) do
    %{"type" => "input_image"}
    |> MessageParts.put_optional("image_url", url)
    |> put_input_detail(block)
    |> put_prompt_cache_breakpoint(block)
  end

  defp inline_part(:file, data, block) do
    %{
      "type" => "input_file",
      "file_data" => MessageParts.data_url(Map.get(block, :mime_type) || "application/pdf", data),
      "filename" => Map.get(block, :filename)
    }
    |> MessageParts.reject_nil_values()
    |> put_input_detail(block)
    |> put_prompt_cache_breakpoint(block)
  end

  defp inline_part(:audio, data, block) do
    %{
      "type" => "input_audio",
      "input_audio" => %{
        "data" => data,
        "format" => MessageParts.audio_format(Map.get(block, :mime_type) || Map.get(block, :format))
      }
    }
  end

  defp assistant_content_items(%Message{content: content, id: id}, opts)
       when is_binary(content) do
    message_id = message_item_id(id)

    case content do
      "" ->
        []

      text ->
        [
          assistant_message_item(
            [%{"type" => "output_text", "text" => text, "annotations" => []}],
            message_id,
            opts
          )
        ]
    end
  end

  defp assistant_content_items(%Message{content: content, id: id}, opts)
       when is_list(content) do
    message_id = message_item_id(id)

    content
    |> Enum.reduce({[], nil, []}, fn block, state ->
      case assistant_content_event(block, message_id, opts) do
        {:message_part, id, part} -> add_assistant_message_part(state, id, part, opts)
        {:item, item} -> add_assistant_raw_item(state, item, opts)
        :skip -> state
      end
    end)
    |> flush_assistant_message_parts(opts)
  end

  defp assistant_content_event(%{type: type, text: text} = block, message_id, _opts)
       when type in [:text, :output_text] and is_binary(text) do
    {:message_part, Map.get(block, :id) || message_id,
     %{
       "type" => "output_text",
       "text" => text,
       "annotations" => Map.get(block, :annotations, [])
     }}
  end

  defp assistant_content_event(%{type: :refusal, refusal: refusal} = block, message_id, _opts)
       when is_binary(refusal) do
    {:message_part, Map.get(block, :id) || message_id, %{"type" => "refusal", "refusal" => refusal}}
  end

  defp assistant_content_event(%ContentBlock.Unknown{value: value}, _message_id, opts)
       when is_map(value) do
    (Map.get(value, :raw_provider_block) || Map.get(value, "raw_provider_block") || %{})
    |> MessageParts.stringify_keys()
    |> Map.merge(MessageParts.stringify_keys(value))
    |> drop_internal_provider_fields()
    |> sanitize_store_replay_item(opts)
  end

  defp assistant_content_event(%ContentBlock.Reasoning{} = block, _message_id, opts) do
    block
    |> sanitize_output_item(opts)
    |> sanitize_store_replay_item(opts)
  end

  defp assistant_content_event(%{"type" => type} = block, _message_id, opts)
       when type in [:reasoning, "reasoning"] do
    block
    |> sanitize_output_item(opts)
    |> sanitize_store_replay_item(opts)
  end

  defp assistant_content_event(%{type: type} = block, _message_id, opts)
       when type in [:function_call, :tool_call, :tool_use] do
    BeamWeaver.MapShape.assert_atom_keys!(block)

    {:item,
     block
     |> MessageParts.stringify_keys()
     |> normalize_function_call_item()
     |> maybe_drop_store_false_id(opts)}
  end

  defp assistant_content_event(%{type: type} = block, _message_id, opts) do
    BeamWeaver.MapShape.assert_atom_keys!(block)
    type = ChatCompletionsWire.provider_type(type)

    if MessageParts.output_block_type?(type) do
      block
      |> sanitize_output_item(opts)
      |> sanitize_store_replay_item(opts)
    else
      :skip
    end
  end

  defp assistant_content_event(_block, _message_id, _opts), do: :skip

  defp add_assistant_message_part({items, nil, []}, id, part, _opts), do: {items, id, [part]}

  defp add_assistant_message_part({items, id, parts}, id, part, _opts),
    do: {items, id, [part | parts]}

  defp add_assistant_message_part({items, id, parts}, next_id, part, opts) do
    {[assistant_message_item(Enum.reverse(parts), id, opts) | items], next_id, [part]}
  end

  defp add_assistant_raw_item({items, nil, []}, item, _opts), do: {[item | items], nil, []}

  defp add_assistant_raw_item({items, id, parts}, item, opts) do
    {[item, assistant_message_item(Enum.reverse(parts), id, opts) | items], nil, []}
  end

  defp flush_assistant_message_parts({items, nil, []}, _opts), do: Enum.reverse(items)

  defp flush_assistant_message_parts({items, id, parts}, opts) do
    Enum.reverse([assistant_message_item(Enum.reverse(parts), id, opts) | items])
  end

  defp assistant_message_item(parts, id, opts) do
    %{"type" => "message", "role" => "assistant", "content" => parts}
    |> MessageParts.put_optional("id", id)
    |> maybe_drop_store_false_id(opts)
  end

  defp assistant_tool_call_items(%Message{content: content, tool_calls: tool_calls} = message, opts)
       when is_list(tool_calls) do
    if ChatCompletionsWire.content_has_tool_call?(content) do
      []
    else
      Enum.map(tool_calls, &tool_call_to_function_call_item(&1, opts)) ++ invalid_call_items(message, opts)
    end
  end

  defp tool_call_to_function_call_item(tool_call, opts) when is_map(tool_call) do
    %{
      "type" => "function_call",
      "id" => Map.get(tool_call, :provider_id) || Map.get(tool_call, :id),
      "call_id" => Map.get(tool_call, :call_id) || Map.get(tool_call, :id),
      "name" => Map.get(tool_call, :name),
      "arguments" => function_call_arguments(tool_call)
    }
    |> MessageParts.reject_nil_values()
    |> maybe_drop_store_false_id(opts)
  end

  defp function_call_arguments(%{arguments: arguments}),
    do: normalize_function_call_arguments(arguments)

  defp function_call_arguments(%{args: args}), do: normalize_function_call_arguments(args)
  defp function_call_arguments(_call), do: "{}"

  defp normalize_function_call_arguments(nil), do: "{}"
  defp normalize_function_call_arguments(arguments) when is_binary(arguments), do: arguments
  defp normalize_function_call_arguments(arguments), do: BeamWeaver.JSON.encode!(arguments)

  # A `function_call` item goes back with the fields the API gave it that the
  # next request needs: the `namespace` of a tool tool search found, `status`
  # and `async`. A decoded call keeps them in its raw item.
  @function_call_fields ["namespace", "status", "async"]

  defp normalize_function_call_item(item) do
    raw = if is_map(item["raw_provider_block"]), do: item["raw_provider_block"], else: %{}
    fields = Map.merge(Map.take(raw, @function_call_fields), Map.take(item, @function_call_fields))

    item
    |> Map.update("type", "function_call", fn
      "tool_call" -> "function_call"
      "tool_use" -> "function_call"
      type -> type
    end)
    |> Map.update("id", item["provider_id"] || item["id"], fn id -> item["provider_id"] || id end)
    |> Map.put_new("arguments", item["args"] || item["input"])
    |> Map.take(["type", "id", "call_id", "name", "arguments"])
    |> Map.merge(fields)
    |> Map.update("arguments", "{}", &normalize_function_call_arguments/1)
    |> MessageParts.reject_nil_values()
  end

  defp sanitize_output_item(%{type: type} = block, _opts)
       when type in [:reasoning, "reasoning"] do
    sanitize_reasoning_output_item(block)
  end

  defp sanitize_output_item(%{"type" => type} = block, _opts)
       when type in [:reasoning, "reasoning"] do
    sanitize_reasoning_output_item(block)
  end

  defp sanitize_output_item(block, _opts) when is_map(block) do
    block
    |> MessageParts.stringify_keys()
    |> drop_internal_provider_fields()
  end

  defp sanitize_reasoning_output_item(block) do
    block
    |> MessageParts.stringify_keys()
    |> Map.take(["type", "id", "summary", "status", "encrypted_content"])
    |> MessageParts.reject_nil_values()
    |> MessageParts.put_optional("content", reasoning_replay_content(block))
  end

  defp sanitize_store_replay_item(%{"type" => "reasoning", "encrypted_content" => encrypted} = item, opts)
       when is_binary(encrypted) and encrypted != "" do
    {:item, maybe_drop_store_false_id(item, opts)}
  end

  defp sanitize_store_replay_item(%{"type" => "reasoning", "content" => [_part | _rest]} = item, opts) do
    {:item, maybe_drop_store_false_id(item, opts)}
  end

  defp sanitize_store_replay_item(%{"type" => "reasoning"} = item, opts) do
    if store_false?(opts), do: :skip, else: {:item, maybe_drop_store_false_id(item, opts)}
  end

  defp sanitize_store_replay_item(%{"type" => "image_generation_call"} = item, opts) do
    if store_false?(opts) and id_only_output_item?(item) do
      :skip
    else
      {:item, maybe_drop_store_false_id(item, opts)}
    end
  end

  defp sanitize_store_replay_item(%{"type" => type} = item, opts)
       when type in ["message", "function_call"] do
    {:item, maybe_drop_store_false_id(item, opts)}
  end

  defp sanitize_store_replay_item(item, _opts), do: {:item, item}

  defp reasoning_replay_content(block) do
    raw_provider_block = BeamWeaver.MapAccess.get(block, :raw_provider_block, %{})
    content = BeamWeaver.MapAccess.get(block, :content)
    raw_content = BeamWeaver.MapAccess.get(raw_provider_block, :content)
    summary = BeamWeaver.MapAccess.get(block, :summary)
    encrypted_content = BeamWeaver.MapAccess.get(block, :encrypted_content)

    cond do
      match?([_part | _rest], content) -> MessageParts.stringify_value(content)
      match?([_part | _rest], raw_content) -> MessageParts.stringify_value(raw_content)
      replayable_plain_reasoning?(summary, encrypted_content) -> plain_reasoning_content(block)
      true -> nil
    end
  end

  defp replayable_plain_reasoning?(summary, encrypted_content),
    do: summary in [nil, []] and encrypted_content in [nil, ""]

  defp plain_reasoning_content(block) do
    case BeamWeaver.MapAccess.first(block, [:reasoning, :text]) do
      text when is_binary(text) and text != "" ->
        [%{"type" => "reasoning_text", "text" => text}]

      _missing ->
        nil
    end
  end

  defp maybe_drop_store_false_id(item, opts) when is_map(item) do
    if store_false?(opts), do: Map.drop(item, ["id"]), else: item
  end

  defp store_false?(opts), do: Keyword.get(opts, :store) == false

  defp id_only_output_item?(item) do
    item
    |> Map.drop(["type", "id", "status"])
    |> map_size()
    |> Kernel.==(0)
  end

  defp drop_internal_provider_fields(value) when is_list(value),
    do: Enum.map(value, &drop_internal_provider_fields/1)

  defp drop_internal_provider_fields(value) when is_map(value) do
    value
    |> Map.drop(["raw_provider_block", "provider_id", "__struct__"])
    |> Map.new(fn {key, nested} -> {key, drop_internal_provider_fields(nested)} end)
  end

  defp drop_internal_provider_fields(value), do: value
end
