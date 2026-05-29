defmodule BeamWeaver.Anthropic.Messages do
  @moduledoc """
  Anthropic Messages API translation for BeamWeaver messages.
  """

  @behaviour BeamWeaver.Provider.MessageTranslator

  alias BeamWeaver.Anthropic.Error
  alias BeamWeaver.Anthropic.OutputParsers
  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Provider.Options

  @impl true
  def encode_message(%Message{} = message, opts \\ []) do
    with {:ok, {system, messages}} <- format_messages([message], opts) do
      case messages do
        [encoded] -> {:ok, encoded}
        [] when not is_nil(system) -> {:ok, %{"system" => system}}
        [] -> {:ok, %{"role" => Atom.to_string(message.role), "content" => ""}}
      end
    end
  end

  @impl true
  def decode_message(payload, opts \\ []), do: response_to_message(payload, opts)

  @impl true
  def encode_messages(messages, opts \\ []), do: format_messages(messages, opts)

  @spec format_messages([Message.t()], keyword()) ::
          {:ok, {String.t() | [map()] | nil, [map()]}} | {:error, Error.t()}
  def format_messages(messages, opts \\ [])

  def format_messages(messages, opts) when is_list(messages) do
    messages
    |> merge_messages()
    |> do_format_messages(opts)
  end

  def format_messages(_messages, _opts) do
    {:error, Error.new(:invalid_messages, "Anthropic input messages must be a list")}
  end

  @spec response_to_message(map(), keyword()) :: {:ok, Message.t()} | {:error, Error.t()}
  def response_to_message(response, _opts \\ [])

  def response_to_message(%{"error" => %{"message" => message} = error}, _opts)
      when is_binary(message) do
    {:error, Error.new(:response_error, message, %{error: Options.stringify_keys(error)})}
  end

  def response_to_message(response, _opts) when is_map(response) do
    content = normalize_response_content(response["content"] || [])
    tool_calls = OutputParsers.extract_tool_calls(response["content"] || [])
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
      tool_calls: tool_calls
    )
    |> case do
      {:ok, message} -> {:ok, message}
      {:error, error} -> {:error, Error.new(error.type, error.message, error.details)}
    end
  end

  def response_to_message(_response, _opts) do
    {:error, Error.new(:invalid_response, "Anthropic response must be a JSON object")}
  end

  defp merge_messages(messages) do
    Enum.reduce(messages, [], fn
      %Message{role: :tool} = message, acc ->
        append_merged(acc, tool_message_as_user(message))

      %Message{} = message, acc ->
        append_merged(acc, message)

      other, acc ->
        append_merged(acc, other)
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
              tool_use_id: message.tool_call_id || message.id,
              is_error: message.status in [:error, "error"]
            }
            |> Options.reject_nil_values()
          ]
      end

    %{message | role: :user, content: content}
  end

  defp do_format_messages(messages, opts) do
    messages = Enum.reverse(messages)

    Enum.reduce_while(Enum.with_index(messages), {:ok, nil, []}, fn {message, index}, {:ok, system, formatted} ->
      case format_message(message, index, length(messages), system, opts) do
        {:ok, new_system, nil} ->
          {:cont, {:ok, new_system, formatted}}

        {:ok, new_system, provider_message} ->
          {:cont, {:ok, new_system, formatted ++ [provider_message]}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, system, formatted} -> {:ok, {system, formatted}}
      {:error, error} -> {:error, error}
    end
  end

  defp format_message(%Message{role: :system} = message, index, _count, system, _opts) do
    if system != nil or index > 0 do
      {:error, Error.new(:invalid_messages, "received multiple non-consecutive system messages")}
    else
      {:ok, system_content(message.content), nil}
    end
  end

  defp format_message(%Message{} = message, index, count, system, opts) do
    with {:ok, content} <- message_content(message, opts) do
      content =
        if message.role == :assistant and index == count - 1 do
          trim_final_assistant_content(content)
        else
          content
        end

      if empty_content?(content) and message.role == :assistant and index < count - 1 do
        {:ok, system, nil}
      else
        {:ok, system, %{"role" => provider_role(message.role), "content" => content}}
      end
    end
  end

  defp format_message(_message, _index, _count, _system, _opts) do
    {:error, Error.new(:invalid_message, "expected a BeamWeaver message")}
  end

  defp provider_role(:assistant), do: "assistant"
  defp provider_role(_role), do: "user"

  defp system_content(content) when is_binary(content), do: content

  defp system_content(content) when is_list(content),
    do: Enum.map(content, &content_block_to_anthropic!/1)

  defp system_content(content), do: to_string(content)

  defp message_content(%Message{role: role, content: content} = message, _opts)
       when is_binary(content) do
    if role == :assistant and message.tool_calls != [] do
      initial = if content == "", do: [], else: [%{"type" => "text", "text" => content}]
      {:ok, add_missing_tool_use_blocks(initial, message)}
    else
      {:ok, content}
    end
  end

  defp message_content(%Message{content: content} = message, _opts) when is_list(content) do
    blocks =
      content
      |> Enum.map(&content_block_to_anthropic!/1)
      |> add_missing_tool_use_blocks(message)

    {:ok, blocks}
  rescue
    exception -> {:error, Error.new(:invalid_content_block, Exception.message(exception))}
  end

  defp content_block_to_anthropic!(%ContentBlock.Text{text: text}),
    do: %{"type" => "text", "text" => text}

  defp content_block_to_anthropic!(%ContentBlock.PlainText{text: text}), do: text_document(text)

  defp content_block_to_anthropic!(%ContentBlock.Image{} = block) do
    %{"type" => "image", "source" => image_source(block.url, block.data, block.mime_type, nil)}
  end

  defp content_block_to_anthropic!(%ContentBlock.File{} = block) do
    %{
      "type" => "document",
      "source" => document_source(block.file_id, block.data, block.mime_type, block.filename, nil)
    }
    |> Options.reject_nil_values()
  end

  defp content_block_to_anthropic!(%ContentBlock.Reasoning{reasoning: text, metadata: metadata}) do
    %{"type" => "thinking", "thinking" => text}
    |> Map.merge(Map.take(Options.stringify_keys(metadata || %{}), ["signature", "cache_control"]))
  end

  defp content_block_to_anthropic!(%ContentBlock.ToolResult{} = block) do
    %{
      "type" => "tool_result",
      "tool_use_id" => block.tool_call_id,
      "content" => tool_result_content(block.content),
      "is_error" => Map.get(block.metadata || %{}, :is_error)
    }
    |> Options.reject_nil_values()
  end

  defp content_block_to_anthropic!(%ContentBlock.Unknown{value: value}) when is_map(value),
    do: Options.stringify_keys(value)

  defp content_block_to_anthropic!(%ContentBlock.Unknown{provider_type: type, value: value}),
    do: %{"type" => type, "value" => value}

  defp content_block_to_anthropic!(block) when is_map(block) do
    BeamWeaver.MapShape.assert_atom_keys!(block)
    provider_block = Options.stringify_keys(block)

    case provider_type(Map.get(block, :type)) do
      nil ->
        raise ArgumentError, "Anthropic content block maps require a type"

      "input_text" ->
        %{"type" => "text", "text" => Map.get(block, :text) || Map.get(block, :content) || ""}

      "output_text" ->
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
              Map.get(block, :base64) || Map.get(block, :data),
              Map.get(block, :mime_type),
              Map.get(block, :filename),
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
          "id" => Map.get(block, :id),
          "name" => Map.get(block, :name),
          "input" => Map.get(block, :args) || Map.get(block, :arguments) || Map.get(block, :input) || %{}
        }
        |> Options.reject_nil_values()
        |> merge_passthrough(provider_block, ["caller", "cache_control"])

      "server_tool_call" ->
        provider_block
        |> Map.put("type", "server_tool_use")
        |> normalize_server_tool_input()

      "server_tool_result" ->
        provider_block

      "tool_result" ->
        provider_block
        |> Map.put_new("tool_use_id", provider_block["tool_call_id"] || provider_block["id"])
        |> Map.drop(["tool_call_id"])

      type
      when type in [
             "text",
             "thinking",
             "redacted_thinking",
             "tool_use",
             "server_tool_use",
             "mcp_tool_use",
             "input_json_delta",
             "code_execution_tool_result",
             "bash_code_execution_tool_result",
             "text_editor_code_execution_tool_result",
             "mcp_tool_result",
             "web_search_tool_result",
             "web_fetch_tool_result",
             "compaction"
           ] ->
        normalize_server_tool_input(provider_block)

      _other ->
        provider_block
    end
  end

  defp content_block_to_anthropic!(block) when is_binary(block),
    do: %{"type" => "text", "text" => block}

  defp content_block_to_anthropic!(block) do
    case ContentBlock.from(block) do
      {:ok, normalized} -> content_block_to_anthropic!(normalized)
      {:error, error} -> raise ArgumentError, error.message
    end
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
    if file_id = block["file_id"] || block["id"] do
      %{"type" => "file", "file_id" => file_id}
    else
      raise ArgumentError, "Anthropic image blocks require url, base64/data, or file_id/id"
    end
  end

  defp document_source(file_id, _data, _mime_type, _filename, _block) when is_binary(file_id) do
    %{"type" => "file", "file_id" => file_id}
  end

  defp document_source(_file_id, data, mime_type, _filename, _block) when is_binary(data) do
    %{"type" => "base64", "media_type" => mime_type || "application/pdf", "data" => data}
  end

  defp document_source(_file_id, _data, _mime_type, _filename, %{"url" => url})
       when is_binary(url) do
    %{"type" => "url", "url" => url}
  end

  defp document_source(_file_id, _data, mime_type, _filename, %{
         "source_type" => "text",
         "text" => text
       }) do
    %{"type" => "text", "media_type" => mime_type || "text/plain", "data" => text}
  end

  defp document_source(_file_id, _data, _mime_type, _filename, _block) do
    raise ArgumentError,
          "Anthropic document blocks require url, base64/data, file_id/id, or source_type text"
  end

  defp merge_passthrough(formatted, block, keys) do
    extras = block["extras"] || block["metadata"] || %{}

    keys
    |> Enum.reduce(formatted, fn key, acc ->
      value = block[key] || extras[key]
      if is_nil(value), do: acc, else: Map.put(acc, key, value)
    end)
  end

  defp normalize_server_tool_input(%{"input" => input, "partial_json" => partial_json} = block)
       when input in [%{}, nil] and is_binary(partial_json) do
    case BeamWeaver.JSON.decode(partial_json) do
      {:ok, decoded} when is_map(decoded) and map_size(decoded) > 0 ->
        Map.put(block, "input", decoded)

      _other ->
        block
    end
  end

  defp normalize_server_tool_input(block), do: block

  defp tool_result_content(content) when is_list(content),
    do: Enum.map(content, &content_block_to_anthropic!/1)

  defp tool_result_content(content), do: content

  defp provider_type(type) when is_atom(type), do: Atom.to_string(type)
  defp provider_type(type), do: type

  defp nested_value(map, key) when is_map(map), do: Map.get(map, key)
  defp nested_value(_value, _key), do: nil

  defp add_missing_tool_use_blocks(content, %Message{role: :assistant, tool_calls: calls})
       when is_list(calls) and calls != [] do
    existing_ids =
      content
      |> Enum.filter(&(is_map(&1) and &1["type"] == "tool_use"))
      |> Enum.map(& &1["id"])
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    missing =
      calls
      |> Enum.reject(fn call ->
        id = BeamWeaver.MapAccess.get(call, :id)
        not is_nil(id) and MapSet.member?(existing_ids, id)
      end)
      |> Enum.map(&tool_call_to_tool_use/1)

    content ++ missing
  end

  defp add_missing_tool_use_blocks(content, _message), do: content

  defp tool_call_to_tool_use(call) when is_map(call) do
    %{
      "type" => "tool_use",
      "id" => BeamWeaver.MapAccess.get(call, :id),
      "name" => BeamWeaver.MapAccess.get(call, :name),
      "input" =>
        BeamWeaver.MapAccess.get(call, :args) ||
          BeamWeaver.MapAccess.get(call, :arguments) ||
          BeamWeaver.MapAccess.get(call, :input) || %{}
    }
    |> Options.reject_nil_values()
  end

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
      Options.stringify_keys(block)
      |> drop_nil_fields(["citations", "caller", "encrypted_content", "text"])

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
          extras: Map.take(block, ["caller"])
        }
        |> Options.reject_nil_values()

      "server_tool_use" ->
        %{
          type: :server_tool_call,
          id: block["id"],
          name: server_tool_name(block["name"]),
          args: block["input"] || decode_partial_json(block["partial_json"]) || %{}
        }
        |> maybe_put_index(block)

      "mcp_tool_use" ->
        %{
          type: :server_tool_call,
          id: block["id"],
          name: "remote_mcp",
          args: block["input"] || decode_partial_json(block["partial_json"]) || %{},
          extras: %{"tool_name" => block["name"], "server_name" => block["server_name"]}
        }
        |> maybe_put_index(block)

      "document" ->
        document_block_to_beamweaver(block)

      "image" ->
        image_block_to_beamweaver(block)

      type when is_binary(type) ->
        if String.ends_with?(type, "_tool_result") do
          %{
            type: :server_tool_result,
            tool_call_id: block["tool_use_id"],
            output: block["content"],
            status: if(block["is_error"], do: "error", else: "success"),
            extras: %{"block_type" => type}
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

  defp document_block_to_beamweaver(%{"source" => %{"type" => "base64"} = source} = block) do
    %{type: :file, base64: source["data"], mime_type: source["media_type"]}
    |> merge_response_extras(block, ["type", "source"])
  end

  defp document_block_to_beamweaver(%{"source" => %{"type" => "url", "url" => url}} = block) do
    %{type: :file, url: url}
    |> merge_response_extras(block, ["type", "source"])
  end

  defp document_block_to_beamweaver(%{"source" => %{"type" => "file", "file_id" => id}} = block) do
    %{type: :file, file_id: id}
    |> merge_response_extras(block, ["type", "source"])
  end

  defp document_block_to_beamweaver(%{"source" => %{"type" => "text", "data" => text} = source} = block) do
    %{type: :plain_text, text: text, mime_type: source["media_type"] || "text/plain"}
    |> merge_response_extras(block, ["type", "source"])
  end

  defp document_block_to_beamweaver(block), do: provider_response_block(block)

  defp image_block_to_beamweaver(%{"source" => %{"type" => "base64"} = source} = block) do
    %{type: :image, base64: source["data"], mime_type: source["media_type"]}
    |> merge_response_extras(block, ["type", "source"])
  end

  defp image_block_to_beamweaver(%{"source" => %{"type" => "url", "url" => url}} = block) do
    %{type: :image, url: url}
    |> merge_response_extras(block, ["type", "source"])
  end

  defp image_block_to_beamweaver(%{"source" => %{"type" => "file", "file_id" => id}} = block) do
    %{type: :image, file_id: id}
    |> merge_response_extras(block, ["type", "source"])
  end

  defp image_block_to_beamweaver(block), do: provider_response_block(block)

  defp merge_response_extras(standard, block, known_fields) do
    extras = Map.drop(block, known_fields)
    if extras == %{}, do: standard, else: Map.put(standard, :extras, extras)
  end

  defp drop_nil_fields(block, fields) do
    Enum.reduce(fields, block, fn field, acc ->
      if Map.get(acc, field) == nil, do: Map.delete(acc, field), else: acc
    end)
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

  defp decode_partial_json(nil), do: nil

  defp decode_partial_json(partial_json) when is_binary(partial_json) do
    case BeamWeaver.JSON.decode(partial_json) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _other -> nil
    end
  end

  defp usage_metadata(nil), do: nil

  defp usage_metadata(usage) when is_map(usage) do
    usage = Options.stringify_keys(usage)
    cache_creation = usage["cache_creation"] || %{}

    cache_creation =
      if is_map(cache_creation), do: Options.stringify_keys(cache_creation), else: %{}

    cache_read = usage["cache_read_input_tokens"] || 0
    cache_creation_total = usage["cache_creation_input_tokens"] || 0
    ephemeral_5m = cache_creation["ephemeral_5m_input_tokens"] || 0
    ephemeral_1h = cache_creation["ephemeral_1h_input_tokens"] || 0
    specific_cache_creation = ephemeral_5m + ephemeral_1h

    input_tokens =
      (usage["input_tokens"] || 0) + cache_read +
        if(specific_cache_creation > 0, do: specific_cache_creation, else: cache_creation_total)

    output_tokens = usage["output_tokens"] || 0

    input_details =
      %{
        cache_read: if(cache_read > 0, do: cache_read),
        cache_creation: if(specific_cache_creation > 0, do: 0, else: positive(cache_creation_total)),
        ephemeral_5m_input_tokens: positive(ephemeral_5m),
        ephemeral_1h_input_tokens: positive(ephemeral_1h)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    %{
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      total_tokens: input_tokens + output_tokens
    }
    |> maybe_put_input_details(input_details)
  end

  defp positive(value) when is_number(value) and value > 0, do: value
  defp positive(_value), do: nil

  defp maybe_put_input_details(metadata, details) when details == %{}, do: metadata

  defp maybe_put_input_details(metadata, details),
    do: Map.put(metadata, :input_token_details, details)

  defp response_metadata(response) do
    %{
      model_provider: "anthropic",
      provider: :anthropic,
      id: response["id"],
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
      headers: response["_beamweaver_response_headers"],
      raw_provider_response: response
    }
    |> Options.reject_nil_values()
  end
end
