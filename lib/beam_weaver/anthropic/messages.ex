defmodule BeamWeaver.Anthropic.Messages do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Provider.ChatCompletionsWire
  alias BeamWeaver.Provider.Options

  def encode_message(%Message{} = message, opts) do
    with {:ok, {system, messages}} <- format_messages([message], opts) do
      case messages do
        [encoded] -> {:ok, encoded}
        [] when not is_nil(system) -> {:ok, %{"system" => system}}
        [] -> {:ok, %{"role" => Atom.to_string(message.role), "content" => ""}}
      end
    end
  end

  def decode_message(payload, _opts), do: response_to_message(payload)

  @spec format_messages([Message.t()], keyword()) ::
          {:ok, {String.t() | [map()] | nil, [map()]}} | {:error, Error.t()}
  def format_messages(messages, opts \\ [])

  def format_messages(messages, opts) when is_list(messages) do
    messages
    |> merge_messages()
    |> do_format_messages(opts)
  rescue
    error in ArgumentError -> {:error, Error.new(:invalid_content_block, Exception.message(error))}
  end

  def format_messages(_messages, _opts) do
    {:error, Error.new(:invalid_messages, "Anthropic input messages must be a list")}
  end

  @spec response_to_message(map()) :: {:ok, Message.t()} | {:error, Error.t()}
  def response_to_message(%{"error" => %{"message" => message} = error}) when is_binary(message) do
    {:error, Error.new(:response_error, message, %{error: Options.stringify_keys(error)})}
  end

  def response_to_message(response) when is_map(response) do
    content = normalize_response_content(response["content"])
    metadata = response_metadata(response)

    message_content =
      case content do
        [%{type: :text, text: text} = block]
        when is_binary(text) and not is_map_key(block, :citations) ->
          text

        [] ->
          ""

        blocks ->
          blocks
      end

    Message.new(:assistant, message_content,
      id: response["id"],
      metadata: metadata,
      response_metadata: metadata,
      usage_metadata: usage_metadata(response["usage"]),
      status: response["stop_reason"],
      tool_calls: tool_calls(response["content"])
    )
  end

  def response_to_message(_response) do
    {:error, Error.new(:invalid_response, "Anthropic response must be a JSON object")}
  end

  defp tool_calls(content) when is_list(content) do
    for %{"type" => "tool_use"} = block <- content do
      BeamWeaver.Core.Messages.tool_call(
        id: block["id"],
        provider_id: block["id"],
        call_id: block["id"],
        name: block["name"],
        args: block["input"] || %{}
      )
    end
  end

  defp tool_calls(_content), do: []

  defp merge_messages(messages) do
    Enum.reduce(messages, [], fn
      %Message{role: :tool} = message, acc -> append_merged(acc, tool_message_as_user(message))
      message, acc -> append_merged(acc, message)
    end)
  end

  defp append_merged([], message), do: [message]

  defp append_merged([%Message{role: role} = last | rest], %Message{role: role} = message)
       when role in [:system, :user] do
    [merge_same_role(last, message) | rest]
  end

  defp append_merged(acc, message), do: [message | acc]

  defp merge_same_role(%Message{} = left, %Message{} = right) do
    merged_content = as_content_blocks(left.content) ++ as_content_blocks(right.content)
    %{right | content: merged_content, id: right.id || left.id}
  end

  defp as_content_blocks(content) when is_binary(content),
    do: [%{type: :text, text: content}]

  defp as_content_blocks(content) when is_list(content), do: content
  defp as_content_blocks(content), do: [%{type: :text, text: to_string(content)}]

  defp tool_message_as_user(%Message{} = message) do
    content =
      case message.content do
        [%{type: :tool_result} | _rest] = blocks ->
          blocks

        content ->
          [
            %{
              type: :tool_result,
              content: content,
              tool_use_id: anthropic_tool_use_id(message.tool_call_id || message.id),
              is_error: message.status in [:error, "error"]
            }
            |> Options.reject_nil_values()
          ]
      end

    %{message | role: :user, content: content}
  end

  defp do_format_messages(messages, opts) do
    messages = Enum.reverse(messages)
    last = length(messages) - 1

    with :ok <- validate_system_message_positions(messages, opts),
         {:ok, formatted} <-
           messages |> Enum.with_index() |> BeamWeaver.Result.traverse(&format_message(&1, last)) do
      case Enum.reject(formatted, &is_nil/1) do
        [{:system, system} | formatted] -> {:ok, {system, formatted}}
        formatted -> {:ok, {nil, formatted}}
      end
    end
  end

  defp format_message({%Message{role: :system} = message, 0}, _last),
    do: {:ok, {:system, system_content(message.content)}}

  defp format_message({%Message{role: :system} = message, _index}, _last), do: {:ok, system_message(message)}

  defp format_message({%Message{} = message, index}, last) do
    with {:ok, content} <- message_content(message) do
      content =
        if message.role == :assistant and index == last, do: trim_final_assistant_content(content), else: content

      if empty_content?(content) and message.role == :assistant and index < last,
        do: {:ok, nil},
        else: {:ok, %{"role" => provider_role(message.role), "content" => content}}
    end
  end

  defp format_message(_message, _last), do: {:error, Error.new(:invalid_message, "expected a BeamWeaver message")}

  defp validate_system_message_positions(messages, opts) do
    indexes = for {%Message{role: :system}, index} <- Enum.with_index(messages), index > 0, do: index

    cond do
      indexes == [] ->
        :ok

      not Keyword.get(opts, :mid_conversation_system_messages, false) ->
        {:error, Error.new(:invalid_messages, "received multiple non-consecutive system messages")}

      Enum.all?(indexes, &valid_mid_conversation_system_position?(messages, &1)) ->
        :ok

      true ->
        {:error,
         Error.new(
           :invalid_messages,
           "mid-conversation system messages must follow a user turn and end the request or precede an assistant turn"
         )}
    end
  end

  defp valid_mid_conversation_system_position?(messages, index) do
    previous = Enum.at(messages, index - 1)
    following = Enum.at(messages, index + 1)

    (match?(%Message{role: :user}, previous) or assistant_ends_with_server_tool_result?(previous)) and
      (is_nil(following) or match?(%Message{role: :assistant}, following))
  end

  defp assistant_ends_with_server_tool_result?(%Message{role: :assistant, content: content})
       when is_list(content) do
    case List.last(content) do
      %{type: type} when type in [:server_tool_result, "server_tool_result"] -> true
      _block -> false
    end
  end

  defp assistant_ends_with_server_tool_result?(_message), do: false

  defp provider_role(:assistant), do: "assistant"
  defp provider_role(_role), do: "user"

  defp system_content(content) when is_binary(content), do: content

  defp system_content(content) when is_list(content),
    do: Enum.map(content, &content_block_to_anthropic!/1)

  defp system_content(content), do: to_string(content)

  defp system_message(%Message{} = message) do
    metadata = Options.stringify_keys(message.metadata || %{})

    %{"role" => "system", "content" => system_content(message.content)}
    |> Options.put_optional("clear_at", Options.normalize_value(metadata["clear_at"]))
    |> Options.put_optional(
      "output_config",
      Options.normalize_option_map(metadata["output_config"])
    )
  end

  defp message_content(%Message{
         role: :assistant,
         response_metadata: %{provider_replay: %{provider: "anthropic", content: content}}
       })
       when is_list(content), do: {:ok, content}

  defp message_content(%Message{role: :assistant, response_metadata: %{model_provider: provider}} = message)
       when is_binary(provider) and provider != "anthropic",
       do: {:ok, portable_content(message)}

  defp message_content(
         %Message{role: :assistant, response_metadata: %{provider_replay: %{provider: provider}}} = message
       )
       when provider != "anthropic",
       do: {:ok, portable_content(message)}

  defp message_content(%Message{role: role, content: content} = message) when is_binary(content) do
    if role == :assistant and (message.tool_calls != [] or invalid_tool_calls(message) != []) do
      {:ok, add_missing_tool_use_blocks(text_blocks(content), message)}
    else
      {:ok, content}
    end
  end

  defp message_content(%Message{content: content} = message) when is_list(content) do
    blocks =
      content
      |> Enum.map(&content_block_to_anthropic!/1)
      |> fold_server_tool_input()
      |> Enum.flat_map(&replayable_block/1)
      |> add_missing_tool_use_blocks(message)

    {:ok, blocks}
  end

  defp text_blocks(""), do: []
  defp text_blocks(text), do: [%{"type" => "text", "text" => text}]

  # A reply from another provider, such as an OpenAI reply after a model
  # fallback, goes as its text and tool calls. Its reasoning and provider
  # blocks have no Anthropic form: Anthropic takes back only its own signed
  # thinking.
  defp portable_content(%Message{content: content} = message) do
    content
    |> List.wrap()
    |> Enum.flat_map(fn
      text when is_binary(text) and text != "" ->
        [%{"type" => "text", "text" => text}]

      %{type: type, text: text} when type in [:text, :output_text] and is_binary(text) and text != "" ->
        [%{"type" => "text", "text" => text}]

      %{type: :refusal, refusal: refusal} when is_binary(refusal) and refusal != "" ->
        [%{"type" => "text", "text" => refusal}]

      _block ->
        []
    end)
    |> add_missing_tool_use_blocks(message)
  end

  # A streamed server tool call is merged from its start block, whose input is
  # empty, and chunks of input JSON at the same stream position. The request
  # takes the start block with the whole input.
  defp fold_server_tool_input(blocks) do
    partial_json =
      for %{"type" => "server_tool_call_chunk", "index" => index} = chunk <- blocks, reduce: %{} do
        acc -> Map.update(acc, index, chunk["args"] || "", &(&1 <> (chunk["args"] || "")))
      end

    Enum.map(blocks, fn
      %{"type" => type, "index" => index} = block
      when type in ["server_tool_use", "mcp_tool_use"] and is_map_key(partial_json, index) ->
        block |> Map.put("partial_json", partial_json[index]) |> normalize_server_tool_input()

      block ->
        block
    end)
  end

  # A streamed message is merged from chunks that carry partial tool input,
  # empty text starts and stream positions. A request takes only the finished
  # blocks; tool calls come back as tool_use blocks from the message's
  # tool calls.
  defp replayable_block(%{"type" => type}) when type in ["input_json_delta", "server_tool_call_chunk"], do: []
  defp replayable_block(%{"type" => "text", "text" => ""}), do: []
  defp replayable_block(block) when is_map(block), do: [Map.delete(block, "index")]
  defp replayable_block(block), do: [block]

  defp content_block_to_anthropic!(%ContentBlock.Text{text: text, metadata: metadata}) do
    %{"type" => "text", "text" => text}
    |> merge_typed_metadata(metadata, ["cache_control"])
  end

  defp content_block_to_anthropic!(%ContentBlock.PlainText{text: text, metadata: metadata}) do
    text
    |> text_document()
    |> merge_typed_metadata(metadata, ["cache_control"])
  end

  defp content_block_to_anthropic!(%ContentBlock.Image{metadata: metadata} = block) do
    source = image_source(block.url, block.data, block.mime_type, %{"file_id" => block.file_id})

    %{"type" => "image", "source" => source}
    |> merge_typed_metadata(metadata, ["cache_control"])
  end

  defp content_block_to_anthropic!(%ContentBlock.File{metadata: metadata} = block) do
    %{"type" => "document", "source" => document_source(block.file_id, block.url, block.data, block.mime_type, nil)}
    |> merge_typed_metadata(metadata, ["cache_control"])
  end

  defp content_block_to_anthropic!(%ContentBlock.Reasoning{reasoning: text, metadata: metadata}) do
    %{"type" => "thinking", "thinking" => text}
    |> Map.merge(Map.take(Options.stringify_keys(metadata || %{}), ["signature", "cache_control"]))
  end

  defp content_block_to_anthropic!(%ContentBlock.ToolResult{} = block) do
    %{
      "type" => "tool_result",
      "tool_use_id" => anthropic_tool_use_id(block.tool_call_id),
      "content" => tool_result_content(block.content),
      "is_error" => Map.get(block.metadata || %{}, :is_error)
    }
    |> Options.reject_nil_values()
  end

  defp content_block_to_anthropic!(%ContentBlock.Unknown{provider_type: type, value: value})
       when is_map(value) do
    {_raw, provider_block} = with_raw_block(value)
    provider_block = Map.put_new(provider_block, "type", type)

    case ChatCompletionsWire.provider_type(type) do
      tool_change when tool_change in ["tool_addition", "tool_removal"] ->
        normalize_tool_change(provider_block, tool_change)

      _other ->
        provider_block
    end
  end

  defp content_block_to_anthropic!(%ContentBlock.Unknown{provider_type: type, value: value}),
    do: %{"type" => type, "value" => value}

  # A content block Anthropic has no input for, such as video or audio.
  defp content_block_to_anthropic!(%{__struct__: module} = block) do
    raise ArgumentError,
          "Anthropic Messages input does not take this #{inspect(Map.get(block, :type, module))} block"
  end

  defp content_block_to_anthropic!(block) when is_map(block) do
    BeamWeaver.MapShape.assert_atom_keys!(block)
    {raw_provider_block, provider_block} = with_raw_block(block)

    case ChatCompletionsWire.provider_type(Map.get(block, :type)) do
      type when type in ["input_text", "output_text"] ->
        %{"type" => "text", "text" => Map.get(block, :text) || Map.get(block, :content) || ""}

      "plain_text" ->
        text_document(Map.get(block, :text) || "")

      "text-plain" ->
        text_document(Map.get(block, :text) || "", provider_block)

      "image_url" ->
        url = nested_value(Map.get(block, :image_url), :url) || Map.get(block, :url)
        %{"type" => "image", "source" => image_source(url, nil, nil, provider_block)}

      "image" ->
        %{
          "type" => "image",
          "source" =>
            image_source(
              Map.get(block, :url) || Map.get(block, :data_uri),
              Map.get(block, :base64) || Map.get(block, :data),
              Map.get(block, :mime_type) || Map.get(block, :format),
              provider_block
            )
        }
        |> merge_passthrough(provider_block, ["cache_control", "citations", "title", "context"])

      "file" ->
        %{
          "type" => "document",
          "source" =>
            document_source(
              Map.get(block, :file_id) || Map.get(block, :id),
              Map.get(block, :url),
              Map.get(block, :base64) || Map.get(block, :data),
              Map.get(block, :mime_type),
              provider_block
            )
        }
        |> merge_passthrough(provider_block, ["cache_control", "citations", "title", "context"])

      "reasoning" ->
        %{"type" => "thinking", "thinking" => Map.get(block, :reasoning) || Map.get(block, :text) || ""}
        |> merge_passthrough(provider_block, ["cache_control", "signature"])

      "tool_call" ->
        %{
          "type" => "tool_use",
          "id" => anthropic_tool_use_id(tool_call_id(block)),
          "name" => Map.get(block, :name),
          "input" => Map.get(block, :args) || Map.get(block, :arguments) || Map.get(block, :input) || %{}
        }
        |> Options.reject_nil_values()
        |> merge_passthrough(provider_block, ["caller", "toolset_name", "cache_control"])

      "server_tool_call" ->
        server_tool_use_block(block, raw_provider_block)

      "server_tool_result" ->
        server_tool_result_block(raw_provider_block)

      type when type in ["tool_addition", "tool_removal"] ->
        normalize_tool_change(provider_block, type)

      "tool_result" ->
        provider_block
        |> Map.put_new("tool_use_id", provider_block["tool_call_id"] || provider_block["id"])
        |> Map.update("tool_use_id", nil, &anthropic_tool_use_id/1)
        |> maybe_put_tool_result_content(block)
        |> Map.drop(["tool_call_id"])

      type
      when type in [
             "text",
             "thinking",
             "redacted_thinking",
             "tool_use",
             "server_tool_use",
             "mcp_tool_use",
             "code_execution_tool_result",
             "bash_code_execution_tool_result",
             "text_editor_code_execution_tool_result",
             "mcp_tool_result",
             "web_search_tool_result",
             "web_fetch_tool_result",
             "compaction"
           ] ->
        provider_block
        |> normalize_anthropic_tool_ids()
        |> normalize_server_tool_input()

      _other ->
        provider_block
    end
  end

  defp content_block_to_anthropic!(block) when is_binary(block),
    do: %{"type" => "text", "text" => block}

  defp content_block_to_anthropic!(block),
    do: raise(ArgumentError, "value cannot be converted to a content block: #{inspect(block)}")

  defp with_raw_block(value) do
    raw =
      case Map.get(value, :raw_provider_block) || Map.get(value, "raw_provider_block") do
        raw when is_map(raw) -> Options.stringify_keys(raw)
        _raw -> %{}
      end

    {raw, Map.merge(raw, value |> Options.stringify_keys() |> Map.drop(["raw_provider_block"]))}
  end

  defp text_document(text, block \\ %{}) do
    %{
      "type" => "document",
      "source" => %{
        "type" => "text",
        "media_type" => block["mime_type"] || "text/plain",
        "data" => text
      }
    }
  end

  defp image_source("data:" <> _rest = data_uri, _data, _mime_type, _block) do
    case ContentBlock.parse_data_uri(data_uri) do
      {:ok, parsed} ->
        %{"type" => "base64", "media_type" => parsed.media_type, "data" => parsed.data}

      {:error, error} ->
        raise ArgumentError, error.message
    end
  end

  defp image_source(url, _data, _mime_type, _block) when is_binary(url) and url != "" do
    %{"type" => "url", "url" => url}
  end

  defp image_source(_url, data, mime_type, _block) when is_binary(data) do
    %{"type" => "base64", "media_type" => mime_type || "image/png", "data" => data}
  end

  defp image_source(_url, _data, _mime_type, block) when is_map(block) do
    file_id = block["file_id"] || block["id"]

    if file_id do
      %{"type" => "file", "file_id" => file_id}
    else
      raise ArgumentError, "Anthropic image blocks require url, base64/data, or file_id/id"
    end
  end

  defp document_source(file_id, _url, _data, _mime_type, _block) when is_binary(file_id),
    do: %{"type" => "file", "file_id" => file_id}

  defp document_source(_file_id, _url, data, mime_type, _block) when is_binary(data),
    do: %{"type" => "base64", "media_type" => mime_type || "application/pdf", "data" => data}

  defp document_source(_file_id, url, _data, _mime_type, _block) when is_binary(url),
    do: %{"type" => "url", "url" => url}

  defp document_source(_file_id, _url, _data, mime_type, %{"source_type" => "text", "text" => text}),
    do: %{"type" => "text", "media_type" => mime_type || "text/plain", "data" => text}

  defp document_source(_file_id, _url, _data, _mime_type, _block) do
    raise ArgumentError,
          "Anthropic document blocks require url, base64/data, file_id/id, or source_type text"
  end

  defp merge_passthrough(formatted, block, keys) do
    extras = block["extras"] || block["metadata"] || %{}
    Enum.reduce(keys, formatted, &BeamWeaver.MapShape.put_present(&2, &1, block[&1] || extras[&1]))
  end

  defp merge_typed_metadata(formatted, metadata, keys) do
    merge_passthrough(formatted, Options.stringify_keys(metadata || %{}), keys)
  end

  # A server tool call decoded from an Anthropic reply goes back as the block
  # Anthropic sent; one made another way is mapped back from its fields.
  defp server_tool_use_block(_block, %{"type" => type} = raw)
       when type in ["server_tool_use", "mcp_tool_use"],
       do: normalize_server_tool_input(raw)

  defp server_tool_use_block(block, _raw) do
    %{
      "type" => "server_tool_use",
      "id" => Map.get(block, :id),
      "name" => anthropic_server_tool_name(Map.get(block, :name)),
      "input" => Map.get(block, :args) || %{}
    }
    |> Options.reject_nil_values()
  end

  # Each server tool has its own result block type, such as
  # `web_search_tool_result`, which only the block Anthropic sent records.
  defp server_tool_result_block(raw) do
    if String.ends_with?(raw["type"] || "", "_tool_result") do
      raw
    else
      raise ArgumentError, "a server tool result can be sent to Anthropic only as the block Anthropic returned"
    end
  end

  # `partial_json` is stream state, not part of the block Anthropic takes back.
  defp normalize_server_tool_input(%{"partial_json" => partial_json} = block) do
    block = Map.delete(block, "partial_json")

    with input when input in [%{}, nil] <- block["input"],
         %{} = decoded <- decode_partial_json(partial_json) do
      Map.put(block, "input", decoded)
    else
      _other -> block
    end
  end

  defp normalize_server_tool_input(block), do: block

  defp normalize_tool_change(%{"tool" => tool} = block, type) when is_map(tool) do
    block
    |> Map.put("type", type)
    |> Map.put("tool", Options.stringify_keys(tool))
    |> Map.drop(["name", "server_name"])
  end

  defp normalize_tool_change(%{"name" => name} = block, type) when is_binary(name) do
    block
    |> Map.put("type", type)
    |> Map.put("tool", %{"type" => "tool_reference", "name" => name})
    |> Map.drop(["name", "server_name"])
  end

  defp normalize_tool_change(block, type), do: Map.put(block, "type", type)

  defp tool_result_content(content) when is_list(content),
    do: Enum.map(content, &content_block_to_anthropic!/1)

  defp tool_result_content(content), do: content

  defp maybe_put_tool_result_content(provider_block, block) do
    case Map.fetch(block, :content) do
      {:ok, content} -> Map.put(provider_block, "content", tool_result_content(content))
      :error -> provider_block
    end
  end

  defp nested_value(map, key) when is_map(map), do: Map.get(map, key)
  defp nested_value(_value, _key), do: nil

  # Invalid calls, whose arguments came back malformed or truncated, go back as
  # `tool_use` blocks too, with the arguments when they parse to an object:
  # the agent answers each with an error `tool_result`, which needs its call.
  defp add_missing_tool_use_blocks(content, %Message{role: :assistant, tool_calls: calls} = message)
       when is_list(calls) do
    add_tool_use_blocks(content, calls ++ Enum.map(invalid_tool_calls(message), &invalid_call_as_tool_use/1))
  end

  defp add_missing_tool_use_blocks(content, _message), do: content

  defp add_tool_use_blocks(content, calls) do
    existing_ids = for %{"type" => "tool_use", "id" => id} when not is_nil(id) <- content, into: MapSet.new(), do: id

    content ++
      for call <- calls,
          not MapSet.member?(existing_ids, call |> tool_call_id() |> anthropic_tool_use_id()),
          do: tool_call_to_tool_use(call)
  end

  defp invalid_tool_calls(%Message{metadata: %{invalid_tool_calls: calls}}) when is_list(calls),
    do: Enum.filter(calls, &(is_map(&1) and is_binary(BeamWeaver.MapAccess.get(&1, :name))))

  defp invalid_tool_calls(_message), do: []

  defp invalid_call_as_tool_use(call) do
    input =
      case BeamWeaver.JSON.decode(BeamWeaver.MapAccess.get(call, :args) || "") do
        {:ok, %{} = args} -> args
        _other -> %{}
      end

    %{
      call_id: tool_call_id(call),
      name: BeamWeaver.MapAccess.get(call, :name),
      args: input
    }
  end

  defp tool_call_to_tool_use(call) when is_map(call) do
    %{
      "type" => "tool_use",
      "id" => call |> tool_call_id() |> anthropic_tool_use_id(),
      "name" => BeamWeaver.MapAccess.get(call, :name),
      "input" =>
        BeamWeaver.MapAccess.get(call, :args) ||
          BeamWeaver.MapAccess.get(call, :arguments) ||
          BeamWeaver.MapAccess.get(call, :input) || %{}
    }
    |> Options.reject_nil_values()
  end

  defp tool_call_id(call) when is_map(call) do
    BeamWeaver.MapAccess.get(call, :call_id) ||
      BeamWeaver.MapAccess.get(call, :id) ||
      BeamWeaver.MapAccess.get(call, :provider_id)
  end

  defp normalize_anthropic_tool_ids(%{"type" => "tool_use"} = block) do
    Map.update(block, "id", nil, &anthropic_tool_use_id/1)
  end

  defp normalize_anthropic_tool_ids(block), do: block

  defp anthropic_tool_use_id(nil), do: nil
  defp anthropic_tool_use_id("toolu_" <> _rest = id), do: id

  defp anthropic_tool_use_id(id) when is_binary(id) do
    digest =
      :crypto.hash(:sha256, id)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    "toolu_bw_" <> digest
  end

  defp anthropic_tool_use_id(id), do: id |> to_string() |> anthropic_tool_use_id()

  defp trim_final_assistant_content(content) when is_binary(content),
    do: String.trim_trailing(content)

  defp trim_final_assistant_content(content) when is_list(content) do
    case List.last(content) do
      %{"type" => "text", "text" => text} when is_binary(text) ->
        List.update_at(content, -1, &Map.put(&1, "text", String.trim_trailing(text)))

      _other ->
        content
    end
  end

  defp empty_content?(""), do: true
  defp empty_content?([]), do: true
  defp empty_content?(_content), do: false

  defp normalize_response_content(content) when is_binary(content),
    do: [%{type: :text, text: content}]

  defp normalize_response_content(content) when is_list(content) do
    Enum.map(content, &response_block_to_beamweaver/1)
  end

  defp normalize_response_content(_content), do: []

  defp response_block_to_beamweaver(block) when is_map(block) do
    block =
      block
      |> Options.stringify_keys()
      |> Map.reject(fn {key, value} ->
        is_nil(value) and key in ["citations", "caller", "encrypted_content", "text"]
      end)

    case block["type"] do
      "thinking" ->
        %{
          type: :reasoning,
          id: block["id"],
          reasoning: block["thinking"],
          signature: block["signature"],
          raw_provider_block: block
        }
        |> Options.reject_nil_values()

      "tool_use" ->
        %{
          type: :tool_call,
          id: block["id"],
          name: block["name"],
          args: block["input"] || %{},
          raw_provider_block: block,
          extras: Map.take(block, ["caller", "toolset_name"])
        }
        |> Options.reject_nil_values()

      # Server tool blocks keep the block Anthropic sent, which is what a
      # later request must replay.
      "server_tool_use" ->
        %{
          type: :server_tool_call,
          id: block["id"],
          name: server_tool_name(block["name"]),
          args: server_tool_input(block),
          raw_provider_block: block
        }
        |> maybe_put_index(block)

      "mcp_tool_use" ->
        %{
          type: :server_tool_call,
          id: block["id"],
          name: "remote_mcp",
          args: server_tool_input(block),
          extras: %{"tool_name" => block["name"], "server_name" => block["server_name"]},
          raw_provider_block: block
        }
        |> maybe_put_index(block)

      "document" ->
        media_response_block(:file, block)

      "image" ->
        media_response_block(:image, block)

      type when is_binary(type) ->
        if String.ends_with?(type, "_tool_result") do
          %{
            type: :server_tool_result,
            tool_call_id: block["tool_use_id"],
            output: block["content"],
            status: if(block["is_error"], do: "error", else: "success"),
            extras: %{"block_type" => type},
            raw_provider_block: block
          }
          |> maybe_put_index(block)
        else
          provider_response_block(block)
        end

      _other ->
        provider_response_block(block)
    end
  end

  defp response_block_to_beamweaver(block), do: block

  defp media_response_block(type, block) do
    standard =
      case block["source"] do
        %{"type" => "base64"} = source ->
          %{type: type, base64: source["data"], mime_type: source["media_type"]}

        %{"type" => "url", "url" => url} ->
          %{type: type, url: url}

        %{"type" => "file", "file_id" => id} ->
          %{type: type, file_id: id}

        %{"type" => "text", "data" => text} = source when type == :file ->
          %{type: :plain_text, text: text, mime_type: source["media_type"] || "text/plain"}

        _source ->
          nil
      end

    case {standard, Map.drop(block, ["type", "source"])} do
      {nil, _extras} -> provider_response_block(block)
      {standard, extras} when extras == %{} -> standard
      {standard, extras} -> Map.put(standard, :extras, extras)
    end
  end

  defp provider_response_block(%{"type" => "text"} = block) do
    %{
      type: :text,
      text: block["text"],
      citations: block["citations"],
      raw_provider_block: block
    }
    |> Options.reject_nil_values()
  end

  defp provider_response_block(%{"type" => type} = block) do
    %{
      type: type,
      id: block["id"],
      text: block["text"],
      content: block["content"],
      raw_provider_block: block
    }
    |> Options.reject_nil_values()
  end

  defp maybe_put_index(map, %{"index" => index}), do: Map.put(map, :index, index)
  defp maybe_put_index(map, _block), do: map

  defp server_tool_name("code_execution"), do: "code_interpreter"
  defp server_tool_name(name), do: name || ""

  defp anthropic_server_tool_name("code_interpreter"), do: "code_execution"
  defp anthropic_server_tool_name(name), do: name

  # Until a streamed tool block is finished, its input is `{}` and the JSON
  # arrives in `partial_json`.
  defp server_tool_input(block) do
    case block["input"] do
      input when is_map(input) and map_size(input) > 0 -> input
      input -> decode_partial_json(block["partial_json"]) || input || %{}
    end
  end

  defp decode_partial_json(partial_json) when is_binary(partial_json) do
    case BeamWeaver.JSON.decode(partial_json) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _other -> nil
    end
  end

  defp decode_partial_json(_partial_json), do: nil

  @doc false
  def usage_metadata(nil), do: nil

  def usage_metadata(usage) when is_map(usage) do
    usage = usage |> Options.stringify_keys() |> effective_compaction_usage()
    cache_creation = if is_map(usage["cache_creation"]), do: usage["cache_creation"], else: %{}
    cache_read = usage["cache_read_input_tokens"] || 0
    ephemeral_5m = cache_creation["ephemeral_5m_input_tokens"] || 0
    ephemeral_1h = cache_creation["ephemeral_1h_input_tokens"] || 0

    cache_creation_tokens =
      if ephemeral_5m + ephemeral_1h > 0,
        do: ephemeral_5m + ephemeral_1h,
        else: usage["cache_creation_input_tokens"] || 0

    input_tokens = (usage["input_tokens"] || 0) + cache_read + cache_creation_tokens
    output_tokens = usage["output_tokens"] || 0

    input_details =
      %{
        cache_read: positive(cache_read),
        cache_creation: positive(cache_creation_tokens),
        ephemeral_5m_input_tokens: positive(ephemeral_5m),
        ephemeral_1h_input_tokens: positive(ephemeral_1h)
      }
      |> BeamWeaver.MapShape.reject_nil_or_empty()

    %{
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      total_tokens: input_tokens + output_tokens,
      input_token_details: input_details,
      output_token_details: output_token_details(usage["output_tokens_details"]),
      service_tier: usage["service_tier"],
      inference_geo: usage["inference_geo"],
      speed: usage["speed"],
      server_tool_use: usage["server_tool_use"],
      fallback_credit: usage["fallback_credit"],
      iterations: usage["iterations"]
    }
    |> BeamWeaver.MapShape.reject_nil_or_empty()
  end

  defp effective_compaction_usage(usage) do
    compaction = Enum.find(List.wrap(usage["iterations"]), &match?(%{"type" => "compaction"}, &1))

    if usage["input_tokens"] in [nil, 0] and usage["output_tokens"] in [nil, 0] and compaction do
      Map.merge(
        usage,
        Map.take(compaction, [
          "input_tokens",
          "output_tokens",
          "cache_read_input_tokens",
          "cache_creation_input_tokens",
          "cache_creation"
        ])
      )
    else
      usage
    end
  end

  defp positive(value) when is_number(value) and value > 0, do: value
  defp positive(_value), do: nil

  defp output_token_details(details) when is_map(details) do
    %{
      thinking_tokens: positive(details["thinking_tokens"]),
      reasoning: positive(details["reasoning_tokens"])
    }
    |> BeamWeaver.MapShape.reject_nil_or_empty()
  end

  defp output_token_details(_details), do: %{}

  @doc false
  def response_metadata(response) do
    header_metadata = response["_beamweaver_response_header_metadata"] || %{}

    %{
      model_provider: "anthropic",
      provider: :anthropic,
      id: response["id"],
      request_id: header_metadata[:request_id],
      type: response["type"],
      role: response["role"],
      model: response["model"],
      model_name: response["model"],
      stop_reason: response["stop_reason"],
      stop_details: response["stop_details"],
      stop_sequence: response["stop_sequence"],
      usage: response["usage"],
      container: response["container"],
      context_management: response["context_management"],
      diagnostics: response["diagnostics"],
      input_transformations: response["input_transformations"],
      headers: header_metadata[:headers],
      transport: BeamWeaver.Provider.ResponseDecoder.transport_metadata(header_metadata),
      raw_provider_response: response
    }
    |> Options.reject_nil_values()
  end
end
