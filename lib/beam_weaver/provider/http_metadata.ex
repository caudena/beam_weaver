defmodule BeamWeaver.Provider.HTTPMetadata do
  @moduledoc false

  alias BeamWeaver.Transport.Redactor
  alias BeamWeaver.Transport.Request

  @spec build(atom() | String.t() | nil, Request.t(), keyword()) :: map()
  def build(provider, %Request{} = request, opts \\ []) do
    %{
      provider: provider,
      method: request.method,
      url: redact_url(request.url),
      timeout_ms: Keyword.get(opts, :timeout),
      headers: Redactor.redact(request.headers),
      request_body_summary: body_summary(request.json || request.body)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  def redact_url(url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.query do
      query =
        uri.query
        |> URI.decode_query()
        |> Map.new(fn {key, value} ->
          if secret_query_key?(key), do: {key, Redactor.redacted()}, else: {key, value}
        end)
        |> URI.encode_query()
        |> String.replace(URI.encode_www_form(Redactor.redacted()), Redactor.redacted())

      uri
      |> Map.put(:query, query)
      |> URI.to_string()
      |> Redactor.redact()
    else
      Redactor.redact(url)
    end
  rescue
    _error -> Redactor.redact(url)
  end

  def redact_url(url), do: Redactor.redact(url)

  defp secret_query_key?(key) do
    normalized =
      key
      |> to_string()
      |> String.downcase()
      |> String.replace("-", "_")

    normalized in ["key", "token"] or
      Enum.any?(["api_key", "apikey", "authorization", "access_token", "secret", "password"], fn part ->
        String.contains?(normalized, part)
      end)
  end

  defp body_summary(nil), do: nil

  defp body_summary(body) when is_binary(body) do
    case BeamWeaver.JSON.decode(body) do
      {:ok, decoded} -> body_summary(decoded)
      {:error, _error} -> %{bytes: byte_size(body)}
    end
  end

  defp body_summary(body) when is_map(body) do
    messages = Map.get(body, "messages") || Map.get(body, :messages)
    input = Map.get(body, "input") || Map.get(body, :input)
    tools = Map.get(body, "tools") || Map.get(body, :tools) || []

    %{
      keys: body |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort(),
      model: Map.get(body, "model") || Map.get(body, :model),
      stream: Map.get(body, "stream") || Map.get(body, :stream),
      messages_count: list_count(messages),
      input_count: list_count(input),
      tools_count: list_count(tools),
      tool_names: tool_names(tools),
      response_format: response_format_summary(Map.get(body, "response_format") || Map.get(body, :response_format)),
      text_format: response_format_summary(get_in(body, ["text", "format"]) || get_in(body, [:text, :format]))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp body_summary(body) when is_list(body), do: %{items_count: length(body)}
  defp body_summary(_body), do: nil

  defp list_count(value) when is_list(value), do: length(value)
  defp list_count(_value), do: nil

  defp tool_names(tools) when is_list(tools) do
    tools
    |> Enum.map(fn
      %{"function" => %{"name" => name}} -> name
      %{function: %{name: name}} -> name
      %{"name" => name} -> name
      %{name: name} -> name
      _tool -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp tool_names(_tools), do: nil

  defp response_format_summary(nil), do: nil

  defp response_format_summary(format) when is_map(format) do
    %{
      type: Map.get(format, "type") || Map.get(format, :type),
      name:
        get_in(format, ["json_schema", "name"]) || get_in(format, [:json_schema, :name]) ||
          Map.get(format, "name") || Map.get(format, :name)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp response_format_summary(_format), do: nil
end
