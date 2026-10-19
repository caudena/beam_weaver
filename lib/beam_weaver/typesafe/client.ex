defmodule BeamWeaver.TypeSafe.Client do
  @moduledoc ~S"""
  HTTP connection and account model discovery for TypeSafe Jev decisions.

  Use BeamWeaver.TypeSafe.DecisionModel for typed evaluation and decoding.
  list_models/2 queries account availability without changing local profiles.
  Configure credentials for the intended base URL and keep raw headers out of
  logs. A model-list response is not evidence of successful decision inference.
  See [TypeSafe](providers/typesafe.md).
  """

  use BeamWeaver.Provider.RedactedInspect

  alias BeamWeaver.Config
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Provider.{HTTPClient, ResponseDecoder}
  alias BeamWeaver.Transport.Response
  alias BeamWeaver.TypeSafe.Decoder

  defstruct [:http, base_url: "https://api.typesafe.ai"]
  @type t :: %__MODULE__{}

  @doc """
  Builds client connection settings from explicit options and provider application configuration; makes no request.
  """
  def new(opts \\ []) do
    opts = if is_map(opts), do: Map.to_list(opts), else: opts
    base_url = Config.option(opts, :base_url, [:typesafe, :base_url], "https://api.typesafe.ai")
    key = Config.option(opts, :api_key, [:typesafe, :api_key])

    http =
      HTTPClient.new(
        Keyword.merge(opts,
          provider: :typesafe,
          endpoint: String.trim_trailing(base_url, "/") <> "/v1/systemone",
          api_key: key,
          auth_header: "authorization",
          auth_prefix: "Bearer"
        )
      )

    %__MODULE__{http: http, base_url: base_url}
  end

  @doc false
  def evaluate(%__MODULE__{} = client, body, opts) do
    with {:ok, raw, request_id} <- decode(HTTPClient.post_json(client.http, body, opts)) do
      Decoder.decode(raw, body["questions"], body["model"], request_id, opts)
    end
  end

  @doc "Lists models available to the account without altering the local profile catalog."
  def list_models(%__MODULE__{} = client, opts \\ []) do
    endpoint = String.trim_trailing(client.base_url, "/") <> "/v1/models"

    with {:ok, %{"models" => models}, request_id} <-
           decode(HTTPClient.get(client.http, Keyword.put(opts, :endpoint, endpoint))),
         true <- is_list(models) and Enum.all?(models, &valid_model?/1) do
      {:ok, %{models: models, request_id: request_id}}
    else
      {:error, _} = error -> error
      _ -> {:error, Error.new(:invalid_provider_response, "invalid TypeSafe model list")}
    end
  end

  defp valid_model?(%{"name" => name, "description" => desc, "release_date" => date}),
    do: is_binary(name) and is_binary(desc) and is_binary(date)

  defp valid_model?(_), do: false

  defp decode(result) do
    with {:ok, body} <- ResponseDecoder.json(result, provider: :typesafe, request_id_header: "x-typesafe-request-id") do
      {:ok, %Response{headers: headers}} = result
      {:ok, body, Map.new(headers)["x-typesafe-request-id"]}
    end
  end
end
