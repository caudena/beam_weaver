defmodule BeamWeaver.Provider.StructuredOutput do
  @moduledoc false

  alias BeamWeaver.Core.Message

  @default_keys [:response_format, :structured_output]

  @doc false
  def maybe_parse(%Message{} = message, opts, parse_opts \\ []) when is_list(opts) do
    keys = Keyword.get(parse_opts, :keys, @default_keys)

    if requested?(opts, keys) do
      parse(message, parser(opts), parse_opts)
    else
      {:ok, message}
    end
  end

  @doc false
  def requested?(opts, keys \\ @default_keys) when is_list(opts) and is_list(keys) do
    Enum.any?(keys, &Keyword.has_key?(opts, &1))
  end

  @doc false
  def parse(%Message{} = message, parser, opts \\ []) do
    with :ok <- maybe_ensure_not_refusal(message, opts),
         :ok <- maybe_ensure_complete(message, opts),
         {:ok, parsed} <- decode_json(message),
         {:ok, parsed} <- run_parser(parser, parsed, message, opts) do
      {:ok, %{message | metadata: Map.put(message.metadata, :parsed, parsed)}}
    else
      {:error, {:decode, error}} -> decode_error(message, error, opts)
      {:error, error} -> {:error, error}
    end
  end

  @doc false
  def parser(opts) when is_list(opts) do
    Keyword.get(opts, :structured_output_parser) ||
      Keyword.get(opts, :structured_output_validator) ||
      parser_from_format(Keyword.get(opts, :response_format)) ||
      parser_from_format(Keyword.get(opts, :structured_output))
  end

  defp parser_from_format(%{} = format) do
    parser = BeamWeaver.MapAccess.get(format, :parser)
    validator = BeamWeaver.MapAccess.get(format, :validator)

    cond do
      is_function(parser, 1) -> parser
      is_function(validator, 1) -> validator
      true -> nil
    end
  end

  defp parser_from_format(_format), do: nil

  defp maybe_ensure_not_refusal(message, opts) do
    if Keyword.get(opts, :refusal?, false) do
      ensure_not_refusal(message, opts)
    else
      :ok
    end
  end

  defp ensure_not_refusal(message, opts) do
    case refusal_block(message.content) do
      nil ->
        :ok

      refusal ->
        {:error,
         provider_error(
           :openai_refusal,
           "#{provider_name(opts)} refused the structured output request",
           opts,
           %{
             refusal: refusal,
             response: response_details(message)
           }
         )}
    end
  end

  defp refusal_block(content) when is_list(content) do
    Enum.find(content, fn block ->
      Map.get(block, :type) == :refusal
    end)
  end

  defp refusal_block(_content), do: nil

  defp maybe_ensure_complete(%Message{} = message, opts) do
    case finish_reason(message) do
      reason when reason in ["max_tokens", "length", "max_output_tokens", "incomplete"] ->
        {:error,
         provider_error(
           :structured_output_parse_error,
           "#{provider_name(opts)} structured output was truncated before valid JSON",
           opts,
           %{
             reason: "finish_reason=#{reason}",
             finish_reason: reason,
             response: response_details(message)
           }
         )}

      _reason ->
        :ok
    end
  end

  defp finish_reason(%Message{status: status}) when is_binary(status), do: normalize_finish_reason(status)

  defp finish_reason(%Message{status: status}) when is_atom(status) and not is_nil(status),
    do: normalize_finish_reason(status)

  defp finish_reason(%Message{metadata: metadata, response_metadata: response_metadata}) do
    metadata_reason(metadata) || metadata_reason(response_metadata) ||
      incomplete_reason(metadata) || incomplete_reason(response_metadata)
  end

  defp metadata_reason(metadata) when is_map(metadata) do
    case metadata_value(metadata, :finish_reason) do
      reason when is_binary(reason) -> normalize_finish_reason(reason)
      reason when is_atom(reason) -> normalize_finish_reason(reason)
      _other -> nil
    end
  end

  defp metadata_reason(_metadata), do: nil

  defp incomplete_reason(metadata) when is_map(metadata) do
    details = metadata_value(metadata, :incomplete_details)

    cond do
      is_map(details) and not is_nil(metadata_value(details, :reason)) ->
        normalize_finish_reason(metadata_value(details, :reason))

      normalize_finish_reason(metadata_value(metadata, :status)) == "incomplete" ->
        "incomplete"

      true ->
        nil
    end
  end

  defp incomplete_reason(_metadata), do: nil

  defp metadata_value(map, key) when is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp normalize_finish_reason(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> normalize_finish_reason()

  defp normalize_finish_reason(reason) when is_binary(reason),
    do: reason |> String.downcase() |> String.replace("-", "_")

  defp normalize_finish_reason(reason), do: reason

  defp decode_json(message) do
    case BeamWeaver.JSON.decode(Message.text(message)) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, error} -> {:error, {:decode, error}}
    end
  end

  defp decode_error(message, error, opts) do
    if Keyword.get(opts, :on_decode_error) == :ok do
      {:ok, message}
    else
      {:error,
       provider_error(
         :structured_output_parse_error,
         "#{provider_name(opts)} structured output was not valid JSON",
         opts,
         %{
           reason: Exception.message(error),
           response: response_details(message)
         }
       )}
    end
  end

  defp run_parser(nil, parsed, _message, _opts), do: {:ok, parsed}

  defp run_parser(parser, parsed, message, opts) when is_function(parser, 1) do
    case parser.(parsed) do
      :ok -> {:ok, parsed}
      true -> {:ok, parsed}
      {:ok, value} -> {:ok, value}
      {:error, reason} -> parser_error(reason, parsed, message, opts)
      false -> parser_error("validator returned false", parsed, message, opts)
      value -> {:ok, value}
    end
  rescue
    exception ->
      parser_error(Exception.message(exception), parsed, message, opts)
  end

  defp parser_error(reason, parsed, message, opts) do
    {:error,
     provider_error(
       :structured_output_parse_error,
       "#{provider_name(opts)} structured output failed validation",
       opts,
       %{
         reason: inspect(reason),
         parsed: clip_value(parsed),
         response: response_details(message)
       }
     )}
  end

  defp response_details(%Message{} = message) do
    text = Message.text(message)

    %{
      role: message.role,
      name: message.name,
      status: message.status,
      content_length: byte_size(text),
      content_preview: clip_text(text),
      metadata: clip_value(message.metadata),
      response_metadata: clip_value(message.response_metadata),
      usage_metadata: clip_value(message.usage_metadata || %{})
    }
  end

  defp clip_value(value), do: clip_value(value, 0)

  defp clip_value(_value, depth) when depth > 6, do: "[truncated depth]"
  defp clip_value(value, _depth) when is_binary(value), do: clip_text(value)

  defp clip_value(value, depth) when is_list(value) do
    max_items = 20

    clipped =
      value
      |> Enum.take(max_items)
      |> Enum.map(&clip_value(&1, depth + 1))

    if length(value) > max_items do
      clipped ++ ["[truncated #{length(value) - max_items} items]"]
    else
      clipped
    end
  end

  defp clip_value(value, depth) when is_map(value) do
    max_entries = 80

    clipped =
      value
      |> Enum.take(max_entries)
      |> Map.new(fn {key, nested} -> {key, clip_value(nested, depth + 1)} end)

    if map_size(value) > max_entries do
      Map.put(clipped, :__truncated_entries__, map_size(value) - max_entries)
    else
      clipped
    end
  end

  defp clip_value(value, _depth), do: value

  defp clip_text(text) when is_binary(text) do
    max = 4_000

    if byte_size(text) > max do
      String.slice(text, 0, max) <> "\n...[truncated #{byte_size(text) - max} bytes]"
    else
      text
    end
  end

  defp provider_error(type, message, opts, details) do
    error_module = Keyword.fetch!(opts, :error_module)
    error_module.new(type, message, details)
  end

  defp provider_name(opts), do: Keyword.get(opts, :provider_name, "Provider")
end
