defmodule BeamWeaver.Anthropic.Client do
  @moduledoc """
  Anthropic Messages API client built on `BeamWeaver.Transport`.
  """

  use BeamWeaver.Provider.RedactedInspect

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Anthropic.Messages
  alias BeamWeaver.Anthropic.Streaming
  alias BeamWeaver.Config
  alias BeamWeaver.Provider.HTTPClient
  alias BeamWeaver.Provider.Options, as: ProviderOptions
  alias BeamWeaver.Provider.ResponseDecoder
  alias BeamWeaver.Transport.Response

  @default_base_url "https://api.anthropic.com"
  @default_endpoint @default_base_url <> "/v1/messages"
  @default_count_tokens_endpoint @default_base_url <> "/v1/messages/count_tokens"
  @default_anthropic_version "2023-06-01"
  @header_fields [
    request_id: "request-id",
    anthropic_organization_id: "anthropic-organization-id",
    anthropic_workspace_id: "anthropic-workspace-id",
    anthropic_ratelimit_input_tokens_limit: "anthropic-ratelimit-input-tokens-limit",
    anthropic_ratelimit_input_tokens_remaining: "anthropic-ratelimit-input-tokens-remaining",
    anthropic_ratelimit_input_tokens_reset: "anthropic-ratelimit-input-tokens-reset",
    anthropic_ratelimit_output_tokens_limit: "anthropic-ratelimit-output-tokens-limit",
    anthropic_ratelimit_output_tokens_remaining: "anthropic-ratelimit-output-tokens-remaining",
    anthropic_ratelimit_output_tokens_reset: "anthropic-ratelimit-output-tokens-reset",
    anthropic_ratelimit_requests_limit: "anthropic-ratelimit-requests-limit",
    anthropic_ratelimit_requests_remaining: "anthropic-ratelimit-requests-remaining",
    anthropic_ratelimit_requests_reset: "anthropic-ratelimit-requests-reset",
    anthropic_ratelimit_tokens_limit: "anthropic-ratelimit-tokens-limit",
    anthropic_ratelimit_tokens_remaining: "anthropic-ratelimit-tokens-remaining",
    anthropic_ratelimit_tokens_reset: "anthropic-ratelimit-tokens-reset"
  ]

  defstruct endpoint: @default_endpoint,
            count_tokens_endpoint: @default_count_tokens_endpoint,
            api_key: nil,
            anthropic_version: @default_anthropic_version,
            betas: [],
            user_profile_id: nil,
            workspace_id: nil,
            default_headers: [],
            transport: nil,
            transport_opts: [],
            timeout: 15_000

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    base_url = Keyword.get(opts, :base_url) || Config.get([:anthropic, :base_url], @default_base_url)

    struct(__MODULE__,
      endpoint: Keyword.get(opts, :endpoint, endpoint(base_url, "v1/messages")),
      count_tokens_endpoint: Keyword.get(opts, :count_tokens_endpoint, endpoint(base_url, "v1/messages/count_tokens")),
      api_key: Config.option(opts, :api_key, [:anthropic, :api_key]),
      anthropic_version: Keyword.get(opts, :anthropic_version, @default_anthropic_version),
      betas: List.wrap(Keyword.get(opts, :betas, [])),
      user_profile_id: Keyword.get(opts, :user_profile_id),
      workspace_id: Keyword.get(opts, :workspace_id),
      default_headers: Keyword.get(opts, :default_headers, []),
      transport: ProviderOptions.default_transport(Keyword.get(opts, :transport)),
      transport_opts: Keyword.get(opts, :transport_opts, []),
      timeout: Keyword.get(opts, :timeout, 15_000)
    )
  end

  @spec messages(t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def messages(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    client
    |> do_request(body, opts)
    |> decode_result(opts)
  end

  @spec messages_stream(t(), map(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def messages_stream(%__MODULE__{} = client, body, opts \\ []) when is_map(body),
    do: do_stream(client, body, opts, &Streaming.text_deltas/1)

  @spec messages_stream_response(t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def messages_stream_response(%__MODULE__{} = client, body, opts \\ []) when is_map(body),
    do: do_stream_collect(client, body, opts, &Streaming.response/1)

  @spec messages_stream_events(t(), map(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def messages_stream_events(%__MODULE__{} = client, body, opts \\ []) when is_map(body),
    do: do_stream(client, body, opts, &Streaming.lifecycle_events/1)

  # The stream ends with the complete reply, decoded like a reply from
  # `messages/3`, followed by its `Done` event.
  @spec messages_stream_typed_events(t(), map(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def messages_stream_typed_events(%__MODULE__{} = client, body, opts \\ []) when is_map(body) or is_binary(body) do
    finish = fn state, response ->
      Streaming.finish_typed_events(state, fn reply ->
        reply |> maybe_attach_stream_headers(response, opts) |> Messages.response_to_message()
      end)
    end

    parser = &Streaming.reply_typed_events/2

    client
    |> http_client(opts)
    |> HTTPClient.stream_typed_sse(
      body,
      Keyword.put(opts, :parser_finalizer, finish),
      parser,
      &decode_stream(&1, parser, opts)
    )
  end

  @spec count_tokens(t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def count_tokens(%__MODULE__{} = client, body, opts \\ []) when is_map(body) do
    client
    |> do_request(body, Keyword.put(opts, :endpoint, client.count_tokens_endpoint))
    |> ResponseDecoder.json(decoder_opts(opts))
  end

  @spec request(t(), map(), keyword()) :: BeamWeaver.Transport.Request.t()
  def request(%__MODULE__{} = client, body, opts \\ []) do
    client |> http_client(opts) |> HTTPClient.request(body, opts)
  end

  @spec endpoint(String.t(), String.t()) :: String.t()
  def endpoint(base_url, path) do
    String.trim_trailing(to_string(base_url), "/") <> "/" <> String.trim_leading(path, "/")
  end

  defp do_request(%__MODULE__{} = client, body, opts) do
    client |> http_client(opts) |> HTTPClient.post_json(body, opts)
  end

  defp do_stream(%__MODULE__{} = client, body, opts, parser) do
    client
    |> http_client(opts)
    |> HTTPClient.stream_sse(body, opts, parser, &decode_stream(&1, parser, opts))
  end

  defp do_stream_collect(%__MODULE__{} = client, body, opts, parser) do
    client
    |> http_client(opts)
    |> HTTPClient.collect_sse(body, opts, &decode_stream(&1, parser, opts))
  end

  defp decode_result(result, opts) do
    with {:ok, decoded} <- ResponseDecoder.json(result, decoder_opts(opts)) do
      case {result, Keyword.get(opts, :decode_response_headers, true)} do
        {{:ok, %Response{headers: headers}}, true} -> {:ok, attach_header_metadata(decoded, headers)}
        _other -> {:ok, decoded}
      end
    end
  end

  defp http_client(%__MODULE__{} = client, opts) do
    %HTTPClient{
      provider: :anthropic,
      endpoint: Keyword.get(opts, :endpoint, client.endpoint),
      api_key: Keyword.get(opts, :api_key, client.api_key),
      auth_header: "x-api-key",
      default_headers: headers(client, opts),
      transport: Keyword.get(opts, :transport, client.transport),
      transport_opts: Keyword.get(opts, :transport_opts, client.transport_opts),
      timeout: Keyword.get(opts, :timeout, client.timeout)
    }
  end

  defp headers(%__MODULE__{} = client, opts) do
    betas = Keyword.get(opts, :betas, client.betas) |> List.wrap() |> Enum.reject(&is_nil/1)

    [
      {"anthropic-version", Keyword.get(opts, :anthropic_version, client.anthropic_version)}
    ]
    |> maybe_put_user_profile_header(Keyword.get(opts, :user_profile_id, client.user_profile_id))
    |> maybe_put_workspace_header(Keyword.get(opts, :workspace_id, client.workspace_id))
    |> maybe_put_beta_header(betas)
    |> Kernel.++(BeamWeaver.Transport.Request.normalize_headers(client.default_headers))
  end

  defp maybe_put_beta_header(headers, []), do: headers

  defp maybe_put_beta_header(headers, betas),
    do: [{"anthropic-beta", Enum.join(betas, ",")} | headers]

  defp maybe_put_user_profile_header(headers, nil), do: headers

  defp maybe_put_user_profile_header(headers, user_profile_id),
    do: [{"anthropic-user-profile-id", to_string(user_profile_id)} | headers]

  defp maybe_put_workspace_header(headers, nil), do: headers

  defp maybe_put_workspace_header(headers, workspace_id),
    do: [{"anthropic-workspace-id", to_string(workspace_id)} | headers]

  defp decode_stream(result, parser, opts) do
    ResponseDecoder.decode(result, decoder_opts(), fn response ->
      {:ok, response.body |> parse_stream_body(parser) |> maybe_attach_stream_headers(response, opts)}
    end)
  end

  defp parse_stream_body(body, parser) when is_function(parser, 1), do: parser.(body)
  defp parse_stream_body(body, parser) when is_function(parser, 2), do: body |> parser.(nil) |> elem(0)

  defp maybe_attach_stream_headers(decoded, %Response{} = response, opts) when is_map(decoded) do
    decoded = attach_header_metadata(decoded, response.headers)

    if Keyword.get(opts, :include_response_headers, false),
      do: Map.put(decoded, "_beamweaver_response_headers", Map.new(response.headers)),
      else: decoded
  end

  defp maybe_attach_stream_headers(decoded, _response, _opts), do: decoded

  defp attach_header_metadata(decoded, headers),
    do: ResponseDecoder.attach_header_metadata(decoded, ResponseDecoder.header_metadata(headers, @header_fields))

  defp decoder_opts(opts \\ []) do
    [
      provider: :anthropic,
      request_id_header: "request-id",
      include_response_headers: Keyword.get(opts, :include_response_headers, false),
      context_overflow?: &context_overflow?/3
    ]
  end

  defp context_overflow?(400, _provider_error, message) when is_binary(message),
    do: String.contains?(String.downcase(message), ["prompt is too long", "context window", "too many tokens"])

  defp context_overflow?(_status, _provider_error, _message), do: false
end
