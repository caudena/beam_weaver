defmodule BeamWeaver.Transport.Request do
  @moduledoc """
  Transport request passed to live and replay providers.
  """

  @enforce_keys [:method, :url]
  defstruct method: :get,
            url: nil,
            headers: [],
            body: nil,
            json: nil,
            options: []

  @type method :: :delete | :get | :head | :options | :patch | :post | :put | String.t()

  @type t :: %__MODULE__{
          method: method(),
          url: String.t(),
          headers: [{String.t(), String.t()}],
          body: iodata() | nil,
          json: term(),
          options: keyword()
        }

  @doc """
  Builds a normalized request struct.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      method: normalize_method(Keyword.fetch!(opts, :method)),
      url: Keyword.fetch!(opts, :url),
      headers: normalize_headers(Keyword.get(opts, :headers, [])),
      body: Keyword.get(opts, :body),
      json: Keyword.get(opts, :json),
      options: Keyword.get(opts, :options, [])
    }
  end

  @doc """
  Returns the request body as a binary when one is present.
  """
  @spec body_binary(t()) :: binary() | nil
  def body_binary(%__MODULE__{json: json}) when not is_nil(json) do
    BeamWeaver.JSON.encode!(json, pretty: true)
  end

  def body_binary(%__MODULE__{body: nil}), do: nil

  def body_binary(%__MODULE__{body: body}) do
    IO.iodata_to_binary(body)
  end

  @doc """
  Returns a canonical JSON body when the request body is JSON.
  """
  @spec canonical_json_body(t()) :: binary() | nil
  def canonical_json_body(%__MODULE__{} = request) do
    with body when is_binary(body) <- body_binary(request),
         {:ok, decoded} <- BeamWeaver.JSON.decode(body) do
      BeamWeaver.JSON.encode!(decoded, pretty: true)
    else
      _not_json -> nil
    end
  end

  @doc """
  Normalizes supported header formats into lowercase binary pairs.
  """
  @spec normalize_headers(map() | list()) :: [{String.t(), String.t()}]
  def normalize_headers(headers) when is_map(headers) do
    headers
    |> Enum.flat_map(fn {key, value} -> normalize_header(key, value) end)
    |> Enum.sort()
  end

  def normalize_headers(headers) when is_list(headers) do
    headers
    |> Enum.flat_map(fn
      {key, value} -> normalize_header(key, value)
      other when is_binary(other) -> []
    end)
    |> Enum.sort()
  end

  defp normalize_header(key, values) when is_list(values) do
    Enum.map(values, &normalize_header_pair(key, &1))
  end

  defp normalize_header(key, value) do
    [normalize_header_pair(key, value)]
  end

  defp normalize_header_pair(key, value) do
    {key |> to_string() |> String.downcase(), to_string(value)}
  end

  defp normalize_method(method) when is_atom(method), do: method

  defp normalize_method(method) when is_binary(method) do
    method
    |> String.downcase()
    |> String.to_existing_atom()
  rescue
    ArgumentError -> String.downcase(method)
  end
end
