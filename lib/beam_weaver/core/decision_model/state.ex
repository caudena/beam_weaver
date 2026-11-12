defmodule BeamWeaver.Core.DecisionModel.State do
  @moduledoc false

  alias BeamWeaver.Core.{ContentBlock, Error, Message}
  alias BeamWeaver.Core.Messages.ToolCall
  alias BeamWeaver.{JSON, MapShape}

  # Project only decision evidence from a message. Message IDs, provider
  # replay metadata, and usage are independent of what a classifier sees.
  def parts(value, encode_media) do
    marker = "bw-media-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower) <> "-"

    with {:ok, data, {_count, media}} <- project(value, {0, []}, {marker, encode_media, false}),
         {:ok, text} <- encode(data) do
      {:ok, interleave(text, marker, media)}
    end
  end

  def assets(value, encode_media, opts \\ []) do
    marker = "bw-asset-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower) <> "-"

    preserve_shape? = Keyword.get(opts, :preserve_message_shape, false)

    with {:ok, data, {_count, media}} <- project(value, {0, []}, {marker, encode_media, preserve_shape?}) do
      assets =
        media
        |> Enum.reverse()
        |> Enum.with_index()
        |> Map.new(fn {asset, index} -> {marker <> Integer.to_string(index), asset} end)

      {:ok, data, assets}
    end
  end

  def json(value, opts \\ []) do
    no_media = fn _block -> invalid("convert other content to text first") end

    preserve_shape? = Keyword.get(opts, :preserve_message_shape, false)
    with {:ok, data, _media} <- project(value, {0, []}, {nil, no_media, preserve_shape?}), do: {:ok, data}
  end

  defp encode(data) do
    case JSON.encode(data) do
      {:ok, text} -> {:ok, text}
      {:error, _} -> invalid("state cannot be encoded as JSON")
    end
  end

  defp interleave(text, _marker, []), do: [text]

  defp interleave(text, marker, media) do
    [first | rest] = String.split(text, marker)
    media = media |> Enum.reverse() |> List.to_tuple()

    [
      first
      | Enum.flat_map(rest, fn segment ->
          {index, tail} = Integer.parse(segment)
          [elem(media, index), tail]
        end)
    ]
  end

  defp project(%Message{} = message, media, {_, _, preserve_shape?} = config) do
    with {:ok, content, media} <- content(message.content, media, config),
         {:ok, calls, media} <- project(message.tool_calls, media, config) do
      data = %{"role" => Atom.to_string(message.role), "content" => content}
      {:ok, put_message_fields(data, message, calls, preserve_shape?), media}
    end
  end

  defp project(%ToolCall{} = call, media, config) do
    project(%{"id" => call.id, "name" => call.name, "args" => call.args}, media, config)
  end

  defp project(%ContentBlock.Image{} = image, media, config), do: project_block(image, media, config)

  defp project(%module{}, _media, _config),
    do: invalid("state contains an unsupported struct; convert it to JSON data first", %{struct: module})

  defp project(map, media, config) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}, media}, fn {key, value}, {:ok, data, media} ->
      with {:ok, key} <- json_key(key),
           false <- Map.has_key?(data, key),
           {:ok, value, media} <- project(value, media, config) do
        {:cont, {:ok, Map.put(data, key, value), media}}
      else
        true -> {:halt, invalid("state contains colliding JSON keys")}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp project(list, media, config) when is_list(list), do: project_list(list, media, config, &project/3)

  defp project(value, media, _config) when is_nil(value) or is_boolean(value) or is_number(value),
    do: {:ok, value, media}

  defp project(value, media, _config) when is_atom(value), do: {:ok, Atom.to_string(value), media}

  defp project(value, media, _config) when is_binary(value) do
    if String.valid?(value), do: {:ok, value, media}, else: invalid("state must be valid UTF-8")
  end

  defp project(_value, _media, _config), do: invalid("state contains a value that isn't JSON data")

  defp put_message_fields(data, message, calls, true) do
    Map.merge(data, %{"name" => message.name, "tool_call_id" => message.tool_call_id, "tool_calls" => calls})
  end

  defp put_message_fields(data, message, calls, false) do
    data
    |> MapShape.put_optional("name", message.name)
    |> MapShape.put_optional("tool_call_id", message.tool_call_id)
    |> MapShape.put_optional("tool_calls", calls)
  end

  defp json_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}

  defp json_key(key) when is_binary(key) do
    if String.valid?(key), do: {:ok, key}, else: invalid("state map keys must be valid UTF-8")
  end

  defp json_key(_key), do: invalid("state map keys must be strings or atoms")

  defp content(blocks, media, config) when is_list(blocks),
    do: project_list(blocks, media, config, &project_block/3)

  defp content(value, _media, {_, _, true}) when not is_binary(value),
    do: invalid("decision messages must contain text or content blocks")

  defp content(value, media, config), do: project(value, media, config)

  defp project_block(text, media, {_, _, true} = config) when is_binary(text), do: project(text, media, config)

  defp project_block(text, media, config) when is_binary(text),
    do: project_block(%{type: :text, text: text}, media, config)

  defp project_block(%{type: type, text: text}, media, config)
       when type in [:text, :plain_text, "text", "plain_text"] and is_binary(text),
       do: project(%{"type" => "text", "text" => text}, media, config)

  defp project_block(%{"type" => type, "text" => text}, media, config)
       when type in ["text", "plain_text"] and is_binary(text),
       do: project_block(%{type: :text, text: text}, media, config)

  defp project_block(block, {index, parts}, {marker, encode_media, _preserve_shape?}) do
    with {:ok, part} <- encode_media.(block) do
      {:ok, %{"type" => "text", "text" => marker <> Integer.to_string(index)}, {index + 1, [part | parts]}}
    end
  end

  defp project_list(values, media, config, project) do
    result =
      Enum.reduce_while(values, {:ok, [], media}, fn value, {:ok, acc, media} ->
        case project.(value, media, config) do
          {:ok, value, media} -> {:cont, {:ok, [value | acc], media}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    with {:ok, values, media} <- result, do: {:ok, Enum.reverse(values), media}
  end

  defp invalid(message, details \\ %{}), do: {:error, Error.new(:invalid_decision_input, message, details)}
end
