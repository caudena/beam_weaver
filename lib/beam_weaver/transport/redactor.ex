defmodule BeamWeaver.Transport.Redactor do
  @moduledoc """
  Redacts secrets before they are stored in cassettes, traces, or errors.
  """

  alias BeamWeaver.Core.Message

  @redacted "**REDACTED**"

  @secret_header_names MapSet.new([
                         "authorization",
                         "cookie",
                         "set-cookie",
                         "x-api-key",
                         "api-key",
                         "openai-api-key",
                         "proxy-authorization"
                       ])

  @secret_key_parts [
    "api_key",
    "apikey",
    "authorization",
    "access_token",
    "refresh_token",
    "secret",
    "password",
    "credential"
  ]

  @doc """
  Redacts known secret shapes inside a term.
  """
  @spec redact(term()) :: term()
  def redact(headers) when is_list(headers) and headers != [] and is_tuple(hd(headers)) do
    Enum.map(headers, fn
      {key, value} ->
        if secret_key?(key),
          do: {to_string(key), @redacted},
          else: {to_string(key), redact(value)}

      other ->
        redact(other)
    end)
  end

  def redact(values) when is_list(values), do: Enum.map(values, &redact/1)

  def redact(%{__struct__: module} = value)
      when module in [Date, DateTime, NaiveDateTime, Time] do
    value
  end

  def redact(%Message{} = message) do
    %Message{
      message
      | content: redact(message.content),
        metadata: redact(message.metadata),
        response_metadata: redact(message.response_metadata),
        usage_metadata: redact(message.usage_metadata),
        artifacts: redact(message.artifacts),
        server_tool_calls: redact(message.server_tool_calls),
        server_tool_results: redact(message.server_tool_results),
        tool_calls: redact(message.tool_calls)
    }
  end

  def redact(%{__struct__: _module} = value) do
    value
    |> Map.from_struct()
    |> redact()
  end

  def redact(value) when is_map(value) do
    Map.new(value, fn {key, map_value} ->
      if secret_key?(key), do: {key, @redacted}, else: {key, redact(map_value)}
    end)
  end

  def redact(value) when is_binary(value) do
    if String.valid?(value) do
      case BeamWeaver.JSON.decode(value) do
        {:ok, decoded} when is_map(decoded) or is_list(decoded) ->
          decoded
          |> redact()
          |> BeamWeaver.JSON.encode!(pretty: true)

        _not_json ->
          redact_string(value)
      end
    else
      value
    end
  end

  def redact(value), do: value

  @doc """
  Returns the redaction marker.
  """
  @spec redacted() :: String.t()
  def redacted, do: @redacted

  defp secret_key?(key) do
    normalized =
      key
      |> to_string()
      |> String.downcase()
      |> String.replace("-", "_")

    MapSet.member?(@secret_header_names, normalized) or
      Enum.any?(@secret_key_parts, &String.contains?(normalized, &1))
  end

  defp redact_string(value) do
    value
    |> String.replace(~r/Bearer\s+[A-Za-z0-9._~+\/=-]+/, "Bearer #{@redacted}")
    |> String.replace(~r/sk-[A-Za-z0-9_\-]+/, @redacted)
  end
end
