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
             response: message
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
           response: message
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
         parsed: parsed,
         response: message
       }
     )}
  end

  defp provider_error(type, message, opts, details) do
    error_module = Keyword.fetch!(opts, :error_module)
    error_module.new(type, message, details)
  end

  defp provider_name(opts), do: Keyword.get(opts, :provider_name, "Provider")
end
