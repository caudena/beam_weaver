defmodule BeamWeaver.Transport.Cassette do
  @moduledoc """
  Replay cassette of recorded HTTP interactions, loaded from VCR-style YAML.

  The file (optionally gzipped) holds one YAML document with matching
  `requests` and `responses` lists. `match/2` finds a recorded response by
  method, URL and body.
  """

  alias BeamWeaver.Transport.Error
  alias BeamWeaver.Transport.Redactor
  alias BeamWeaver.Transport.Request
  alias BeamWeaver.Transport.Response

  defstruct path: nil, interactions: []

  @type interaction :: %{
          request: map(),
          response: Response.t()
        }

  @type t :: %__MODULE__{
          path: Path.t() | nil,
          interactions: [interaction()]
        }

  @doc """
  Loads a gzipped or plain YAML cassette.
  """
  @spec load(Path.t()) :: {:ok, t()} | {:error, Error.t()}
  def load(path) do
    expanded = Path.expand(path)

    with {:ok, contents} <- read(expanded),
         {:ok, yaml} <- unzip_if_needed(expanded, contents),
         {:ok, document} <- parse_yaml(yaml),
         {:ok, interactions} <- interactions(document) do
      {:ok, %__MODULE__{path: expanded, interactions: interactions}}
    end
  end

  @doc """
  Finds the first interaction matching `request`.
  """
  @spec match(t(), Request.t()) :: {:ok, Response.t()} | {:error, Error.t()}
  def match(%__MODULE__{} = cassette, %Request{} = request) do
    normalized_request = normalize_request(request)

    case Enum.find(cassette.interactions, &matches?(&1.request, normalized_request)) do
      %{response: response} ->
        {:ok, response}

      nil ->
        {:error, mismatch_error(cassette, normalized_request)}
    end
  end

  @doc """
  Converts a request into the cassette matching shape.
  """
  @spec normalize_request(Request.t()) :: map()
  def normalize_request(%Request{} = request) do
    %{
      method: request.method |> to_string() |> String.upcase(),
      url: request.url,
      json_body: Request.canonical_json_body(request),
      body: Request.body_binary(request)
    }
  end

  defp read(path) do
    case File.read(path) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, reason} ->
        {:error, Error.new(:missing_cassette, "cassette not found: #{path}", %{reason: reason})}
    end
  end

  defp unzip_if_needed(path, contents) do
    if String.ends_with?(path, ".gz") do
      try do
        {:ok, :zlib.gunzip(contents)}
      rescue
        ErlangError ->
          {:error, Error.new(:invalid_cassette, "cassette gzip data is invalid", %{path: path})}
      end
    else
      {:ok, contents}
    end
  end

  defp parse_yaml(contents) do
    case BeamWeaver.YAML.decode(contents, string_keys: true) do
      {:ok, document} ->
        {:ok, document}

      {:error, :not_one_document} ->
        {:error, Error.new(:invalid_cassette, "cassette must contain exactly one YAML document")}

      {:error, {:invalid, reason}} ->
        {:error, Error.new(:invalid_cassette, "cassette YAML could not be parsed", %{reason: reason})}
    end
  end

  defp interactions(%{"requests" => requests, "responses" => responses})
       when is_list(requests) and is_list(responses) and length(requests) == length(responses) do
    interactions =
      requests
      |> Enum.zip(responses)
      |> Enum.map(fn {request, response} ->
        %{request: cassette_request(request), response: cassette_response(response)}
      end)

    {:ok, interactions}
  end

  defp interactions(_document) do
    {:error, Error.new(:invalid_cassette, "cassette must contain matching requests and responses lists")}
  end

  defp cassette_request(request) do
    method = request |> Map.get("method", "") |> to_string() |> String.upcase()
    url = request |> Map.get("uri", "") |> wildcard_redacted()
    body = Map.get(request, "body")

    %{
      method: method,
      url: url,
      json_body: canonical_json(body),
      body: body
    }
  end

  defp cassette_response(response) do
    Response.new(
      status: get_in(response, ["status", "code"]),
      headers: Map.get(response, "headers", []),
      body: get_in(response, ["body", "string"]) || "",
      metadata: %{source: :cassette}
    )
  end

  defp matches?(cassette_request, request) do
    cassette_request.method == request.method and (is_nil(cassette_request.url) or cassette_request.url == request.url) and
      body_matches?(cassette_request, request)
  end

  defp body_matches?(%{json_body: nil, body: nil}, %{body: nil}), do: true

  defp body_matches?(%{json_body: json_body}, %{json_body: json_body}) when not is_nil(json_body),
    do: true

  defp body_matches?(%{body: body}, %{body: body}) when not is_nil(body), do: true
  defp body_matches?(_cassette_request, _request), do: false

  defp mismatch_error(cassette, request) do
    Error.new(:cassette_mismatch, "no matching cassette interaction", %{
      cassette: cassette.path,
      request: Redactor.redact(request),
      expected: Enum.map(cassette.interactions, &Redactor.redact(&1.request))
    })
  end

  defp canonical_json(nil), do: nil

  defp canonical_json(body) when is_binary(body) do
    case BeamWeaver.JSON.decode(body) do
      {:ok, decoded} -> BeamWeaver.JSON.encode!(decoded, pretty: true)
      {:error, _error} -> nil
    end
  end

  defp wildcard_redacted("**REDACTED**"), do: nil
  defp wildcard_redacted(value), do: value
end
