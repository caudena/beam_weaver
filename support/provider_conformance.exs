defmodule BeamWeaver.TestSupport.ProviderConformance do
  @moduledoc false

  import ExUnit.Assertions

  alias BeamWeaver.Agent.StructuredOutput
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Transport.Redactor
  alias BeamWeaver.Transport.Request
  alias BeamWeaver.Transport.Response

  @fixture_root Path.expand("../test/fixtures/provider_conformance", __DIR__)
  @redacted Redactor.redacted()

  @redacted_header_names MapSet.new([
                           "cf-ray",
                           "date",
                           "openai-organization",
                           "openai-project",
                           "request-id",
                           "server",
                           "x-request-id",
                           "x-ratelimit-limit-requests",
                           "x-ratelimit-limit-tokens",
                           "x-ratelimit-remaining-requests",
                           "x-ratelimit-remaining-tokens",
                           "x-ratelimit-reset-requests",
                           "x-ratelimit-reset-tokens"
                         ])

  @redacted_key_parts [
    "account",
    "api_key",
    "apikey",
    "authorization",
    "credential",
    "created",
    "created_at",
    "org_id",
    "organization",
    "password",
    "request_id",
    "secret",
    "timestamp"
  ]

  @provider_modules %{
    openai: BeamWeaver.OpenAI.ChatModel,
    xai: BeamWeaver.XAI.ChatModel,
    google: BeamWeaver.Google.ChatModel,
    moonshot: BeamWeaver.Moonshot.ChatModel
  }

  @provider_models %{
    openai: "gpt-5.4-mini",
    xai: "grok-4.3",
    google: "gemini-3.5-flash",
    moonshot: "kimi-k2.6"
  }

  @provider_api_keys %{
    openai: "sk-provider-conformance",
    xai: "xai-provider-conformance",
    google: "google-provider-conformance",
    moonshot: "moonshot-provider-conformance"
  }

  def fixture_root, do: @fixture_root

  def fixture_path(provider, scenario) do
    Path.join([@fixture_root, provider_name!(provider), "#{scenario}.json"])
  end

  def load!(provider, scenario) do
    provider
    |> fixture_path(scenario)
    |> load_path!()
  end

  def load_path!(path) do
    path
    |> File.read!()
    |> BeamWeaver.JSON.decode!()
  end

  def model(provider, scenario, opts \\ []) do
    provider = provider_atom!(provider)
    module = Map.fetch!(@provider_modules, provider)

    transport_opts =
      opts
      |> Keyword.get(:transport_opts, [])
      |> Keyword.put_new(:fixture_path, fixture_path(provider, scenario))
      |> Keyword.put_new(:parent, self())

    model_opts =
      opts
      |> Keyword.drop([:transport_opts])
      |> Keyword.put_new(:model, Map.fetch!(@provider_models, provider))
      |> Keyword.put_new(:api_key, Map.fetch!(@provider_api_keys, provider))
      |> Keyword.put(:transport, BeamWeaver.TestSupport.ProviderConformance.Transport)
      |> Keyword.put(:transport_opts, transport_opts)

    module.new(model_opts)
  end

  def capture_model(provider, scenario, opts \\ []) do
    provider = provider_atom!(provider)
    module = Map.fetch!(@provider_modules, provider)
    api_key = Keyword.fetch!(opts, :api_key)

    transport_opts =
      opts
      |> Keyword.get(:transport_opts, [])
      |> Keyword.put(:capture_provider, provider)
      |> Keyword.put(:capture_scenario, scenario)
      |> Keyword.put(:capture_path, fixture_path(provider, scenario))

    model_opts =
      opts
      |> Keyword.drop([:transport_opts, :api_key])
      |> Keyword.put_new(:model, Map.fetch!(@provider_models, provider))
      |> Keyword.put(:api_key, api_key)
      |> Keyword.put(:transport, BeamWeaver.TestSupport.ProviderConformance.CaptureTransport)
      |> Keyword.put(:transport_opts, transport_opts)

    module.new(model_opts)
  end

  def weather_tool do
    Tool.from_function!(
      name: "get_weather",
      description: "Return current weather for a city.",
      input_schema: %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{"city" => %{"type" => "string"}},
        "required" => ["city"]
      },
      handler: fn args, _opts -> args end
    )
  end

  def answer_schema do
    %{
      "title" => "answer_output",
      "description" => "A short answer.",
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{"answer" => %{"type" => "string"}},
      "required" => ["answer"]
    }
  end

  def structured_output(:provider), do: StructuredOutput.provider(answer_schema(), name: "answer_output")
  def structured_output(:tool), do: StructuredOutput.tool(answer_schema())
  def structured_output(:auto), do: StructuredOutput.auto(answer_schema())

  def assert_request!(provider, scenario, timeout \\ 100) do
    provider = provider_atom!(provider)
    scenario = to_string(scenario)
    fixture = load!(provider, scenario)
    expected = Map.fetch!(fixture, "request")

    assert_receive {:provider_conformance_request, ^provider, ^scenario, actual}, timeout
    assert actual == expected
  end

  def assert_matches_expected!(actual, expected) do
    assert_subset(normalize_for_fixture(actual), expected)
  end

  def assert_message!(%Message{} = message, expected) when is_map(expected) do
    message
    |> message_snapshot()
    |> assert_matches_expected!(expected)
  end

  def assert_error!({:error, error}, expected) when is_map(expected) do
    error
    |> error_snapshot()
    |> assert_matches_expected!(expected)
  end

  def message_snapshot(%Message{} = message) do
    %{
      "role" => Atom.to_string(message.role),
      "text" => Message.text(message),
      "id" => message.id,
      "status" => normalize_for_fixture(message.status),
      "tool_calls" => Enum.map(message.tool_calls || [], &tool_call_snapshot/1),
      "usage_metadata" => normalize_for_fixture(message.usage_metadata),
      "metadata" => metadata_snapshot(message.metadata)
    }
    |> reject_nil_values()
  end

  def error_snapshot(%Error{} = error) do
    %{
      "type" => Atom.to_string(error.type),
      "message" => error.message,
      "details" => normalize_for_fixture(error.details)
    }
  end

  def error_snapshot(%{type: type, message: message, details: details}) do
    %{
      "type" => normalize_for_fixture(type),
      "message" => message,
      "details" => normalize_for_fixture(details)
    }
  end

  def error_snapshot(error), do: %{"message" => inspect(error)}

  def tool_call_snapshot(call) when is_map(call) do
    %{
      "id" => value(call, :id),
      "provider_id" => value(call, :provider_id),
      "call_id" => value(call, :call_id),
      "name" => value(call, :name),
      "args" => normalize_for_fixture(value(call, :args) || value(call, :arguments)),
      "thought_signature" => value(call, :thought_signature)
    }
    |> reject_nil_values()
  end

  def sanitize_request(%Request{} = request) do
    request_body =
      cond do
        not is_nil(request.json) -> normalize_for_fixture(request.json)
        is_binary(Request.body_binary(request)) -> decode_json_or_string(Request.body_binary(request))
        true -> nil
      end

    %{
      "method" => request.method |> to_string() |> String.upcase(),
      "url" => request.url,
      "headers" => sanitize_headers(request.headers),
      "json" => request_body
    }
    |> reject_nil_values()
  end

  def sanitize_response(%Response{} = response, body_override \\ nil) do
    body = body_override || response.body

    %{
      "status" => response.status,
      "headers" => sanitize_headers(response.headers),
      "body" => sanitize_response_body(body)
    }
    |> reject_nil_values()
  end

  def put_expected!(path, expected) do
    fixture =
      path
      |> load_path!()
      |> Map.put("expected", normalize_for_fixture(expected))

    write_json!(path, fixture)
  end

  def write_capture!(path, provider, scenario, request, result, body_override \\ nil) do
    fixture =
      %{
        "provider" => provider_name!(provider),
        "scenario" => to_string(scenario),
        "request" => sanitize_request(request),
        "response" => capture_response(result, body_override)
      }
      |> normalize_for_fixture()

    write_json!(path, fixture)
  end

  def provider_atom!(provider) when provider in [:openai, :xai, :google, :moonshot], do: provider
  def provider_atom!("openai"), do: :openai
  def provider_atom!("xai"), do: :xai
  def provider_atom!("google"), do: :google
  def provider_atom!("moonshot"), do: :moonshot

  def provider_atom!(other) do
    raise ArgumentError,
          "unsupported provider #{inspect(other)}; expected :openai, :xai, :google, or :moonshot"
  end

  def provider_name!(provider), do: provider_atom!(provider) |> Atom.to_string()

  defp capture_response({:ok, %Response{} = response}, body_override), do: sanitize_response(response, body_override)

  defp capture_response({:error, error}, _body_override) do
    %{"error" => error_snapshot(error)}
  end

  defp sanitize_headers(headers) do
    headers
    |> Request.normalize_headers()
    |> Redactor.redact()
    |> Enum.map(fn {key, value} ->
      value =
        if MapSet.member?(@redacted_header_names, key),
          do: @redacted,
          else: value

      [key, value]
    end)
    |> Enum.sort()
  end

  defp sanitize_response_body(body) when is_binary(body) do
    case BeamWeaver.JSON.decode(body) do
      {:ok, decoded} when is_map(decoded) or is_list(decoded) ->
        redact_fixture_term(decoded)

      _not_json ->
        Redactor.redact(body)
    end
  end

  defp sanitize_response_body(body), do: redact_fixture_term(body)

  defp decode_json_or_string(nil), do: nil

  defp decode_json_or_string(body) when is_binary(body) do
    case BeamWeaver.JSON.decode(body) do
      {:ok, decoded} -> normalize_for_fixture(decoded)
      {:error, _error} -> body
    end
  end

  defp metadata_snapshot(metadata) when is_map(metadata) do
    metadata
    |> Map.drop([:raw_provider_response, "raw_provider_response"])
    |> normalize_for_fixture()
    |> Map.take([
      "id",
      "model",
      "model_name",
      "model_provider",
      "provider",
      "finish_reason",
      "status",
      "parsed",
      "usage",
      "token_usage",
      "reasoning_content",
      "incomplete_details",
      "service_tier"
    ])
    |> reject_nil_values()
  end

  defp metadata_snapshot(_metadata), do: %{}

  defp normalize_for_fixture(%Message{} = message), do: message_snapshot(message)
  defp normalize_for_fixture(%Error{} = error), do: error_snapshot(error)

  defp normalize_for_fixture(%{__struct__: _module} = struct) do
    struct
    |> Map.from_struct()
    |> normalize_for_fixture()
  end

  defp normalize_for_fixture(map) when is_map(map) do
    map
    |> Map.new(fn {key, val} -> {normalize_key(key), normalize_for_fixture(val)} end)
    |> reject_nil_values()
  end

  defp normalize_for_fixture(values) when is_list(values), do: Enum.map(values, &normalize_for_fixture/1)
  defp normalize_for_fixture(value) when is_boolean(value), do: value
  defp normalize_for_fixture(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_for_fixture(value), do: value

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)

  defp redact_fixture_term(%{__struct__: _module} = struct), do: struct |> Map.from_struct() |> redact_fixture_term()

  defp redact_fixture_term(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      if redacted_key?(key),
        do: {normalize_key(key), @redacted},
        else: {normalize_key(key), redact_fixture_term(value)}
    end)
  end

  defp redact_fixture_term(values) when is_list(values), do: Enum.map(values, &redact_fixture_term/1)
  defp redact_fixture_term(value) when is_binary(value), do: Redactor.redact(value)
  defp redact_fixture_term(value) when is_boolean(value), do: value
  defp redact_fixture_term(value) when is_atom(value), do: Atom.to_string(value)
  defp redact_fixture_term(value), do: value

  defp redacted_key?(key) do
    normalized =
      key
      |> normalize_key()
      |> String.downcase()
      |> String.replace("-", "_")

    Enum.any?(@redacted_key_parts, &String.contains?(normalized, &1))
  end

  defp reject_nil_values(map) when is_map(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp value(map, key) when is_map(map), do: BeamWeaver.MapAccess.get(map, key)

  defp assert_subset(actual, expected) when is_map(actual) and is_map(expected) do
    Enum.each(expected, fn {key, expected_value} ->
      assert Map.has_key?(actual, key), "expected key #{inspect(key)} in #{inspect(actual)}"
      assert_subset(Map.fetch!(actual, key), expected_value)
    end)
  end

  defp assert_subset(actual, expected) when is_list(actual) and is_list(expected) do
    assert length(actual) == length(expected)

    actual
    |> Enum.zip(expected)
    |> Enum.each(fn {actual_item, expected_item} -> assert_subset(actual_item, expected_item) end)
  end

  defp assert_subset(actual, expected), do: assert(actual == expected)

  defp write_json!(path, data) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, BeamWeaver.JSON.encode!(data, pretty: true) <> "\n")
  end
end

defmodule BeamWeaver.TestSupport.ProviderConformance.Transport do
  @moduledoc false

  @behaviour BeamWeaver.Transport

  alias BeamWeaver.TestSupport.ProviderConformance
  alias BeamWeaver.Transport.Request
  alias BeamWeaver.Transport.Response

  @impl true
  def request(%Request{} = request, opts) do
    fixture = load_fixture!(opts)
    notify_parent(opts, fixture, request)

    fixture
    |> Map.fetch!("response")
    |> response_from_fixture()
  end

  @impl true
  def stream_reduce(%Request{} = request, opts, acc, reducer) when is_function(reducer, 2) do
    fixture = load_fixture!(opts)
    notify_parent(opts, fixture, request)
    response_fixture = Map.fetch!(fixture, "response")

    case response_from_fixture(response_fixture) do
      {:ok, %Response{status: status} = response} when status in 200..299 ->
        body = response_body(response_fixture)
        acc = if is_binary(body) and body != "", do: reducer.(acc, body), else: acc
        {:ok, response, acc}

      {:ok, %Response{} = response} ->
        {:ok, response, acc}
    end
  end

  defp load_fixture!(opts) do
    opts
    |> Keyword.fetch!(:fixture_path)
    |> ProviderConformance.load_path!()
  end

  defp notify_parent(opts, fixture, %Request{} = request) do
    if parent = Keyword.get(opts, :parent) do
      provider = ProviderConformance.provider_atom!(Map.fetch!(fixture, "provider"))
      scenario = Map.fetch!(fixture, "scenario")

      send(
        parent,
        {:provider_conformance_request, provider, scenario, ProviderConformance.sanitize_request(request)}
      )
    end
  end

  defp response_from_fixture(%{"status" => status} = response) do
    {:ok,
     Response.new(
       status: status,
       headers: response_headers(response),
       body: response_body(response),
       metadata: %{
         source: :provider_conformance_fixture,
         provider_conformance: true
       }
     )}
  end

  defp response_headers(response) do
    response
    |> Map.get("headers", [])
    |> Enum.map(fn [key, value] -> {key, value} end)
  end

  defp response_body(%{"sse" => body}) when is_binary(body), do: body
  defp response_body(%{"body" => body}) when is_binary(body), do: body
  defp response_body(%{"body" => body}), do: BeamWeaver.JSON.encode!(body)
  defp response_body(_response), do: ""
end

defmodule BeamWeaver.TestSupport.ProviderConformance.CaptureTransport do
  @moduledoc false

  @behaviour BeamWeaver.Transport

  alias BeamWeaver.Provider.Options, as: ProviderOptions
  alias BeamWeaver.TestSupport.ProviderConformance
  alias BeamWeaver.Transport
  alias BeamWeaver.Transport.Request

  @capture_keys [
    :capture_provider,
    :capture_scenario,
    :capture_path,
    :delegate_transport
  ]

  @impl true
  def request(%Request{} = request, opts) do
    delegate = Keyword.get(opts, :delegate_transport, ProviderOptions.default_transport(nil))
    result = Transport.request(delegate, request, delegate_opts(opts))
    write_capture!(opts, request, result)
    result
  end

  @impl true
  def stream_reduce(%Request{} = request, opts, acc, reducer) when is_function(reducer, 2) do
    delegate = Keyword.get(opts, :delegate_transport, ProviderOptions.default_transport(nil))

    result =
      Transport.stream_reduce(delegate, request, delegate_opts(opts), {acc, []}, fn {user_acc, chunks}, chunk ->
        {reducer.(user_acc, chunk), [chunk | chunks]}
      end)

    case result do
      {:ok, response, {user_acc, chunks}} ->
        body = chunks |> Enum.reverse() |> IO.iodata_to_binary()
        write_capture!(opts, request, {:ok, response}, body)
        {:ok, response, user_acc}

      {:error, error, {user_acc, chunks}} ->
        body = chunks |> Enum.reverse() |> IO.iodata_to_binary()
        write_capture!(opts, request, {:error, error}, body)
        {:error, error, user_acc}
    end
  end

  defp delegate_opts(opts), do: Keyword.drop(opts, @capture_keys)

  defp write_capture!(opts, %Request{} = request, result, body_override \\ nil) do
    ProviderConformance.write_capture!(
      Keyword.fetch!(opts, :capture_path),
      Keyword.fetch!(opts, :capture_provider),
      Keyword.fetch!(opts, :capture_scenario),
      request,
      result,
      body_override
    )
  end
end
