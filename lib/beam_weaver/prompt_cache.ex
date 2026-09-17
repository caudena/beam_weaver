defmodule BeamWeaver.PromptCache do
  @moduledoc """
  Helpers for stable provider prompt-cache keys.
  """

  alias BeamWeaver.Agent.ModelResolver

  @default_version "v1"
  @digest_length 20

  # OpenAI rejects a `prompt_cache_key` longer than 64 bytes with a 400; the
  # other providers treat the key as an opaque string, so one limit serves all.
  @max_key_bytes 64

  @doc """
  Builds a stable prompt-cache key from a scope, provider/model id, and static prompt.

  The key is `bwpc:<version>:<scope>:<provider-model>:<prompt digest>`. When
  that exceeds #{@max_key_bytes} bytes (a long scope such as an agent name, or
  a long model id) the scope, model and digest collapse into one hash, so the
  key still changes with any of them but always fits the provider limit.
  """
  @spec key(term(), term(), String.t() | nil, keyword()) :: String.t()
  def key(scope, provider_model, static_prompt, opts \\ []) do
    version = sanitize(Keyword.get(opts, :version, @default_version), "v1")
    digest = digest(static_prompt || "")
    prefix = "bwpc:" <> version <> ":"
    body = Enum.join([sanitize(scope, "default"), sanitize(provider_model, "unknown"), digest], ":")

    cond do
      byte_size(prefix) + byte_size(body) <= @max_key_bytes ->
        prefix <> body

      # Keep the version readable when at least 16 hash characters still fit.
      byte_size(prefix) + 2 + 16 <= @max_key_bytes ->
        prefix <> "h:" <> hash(body, @max_key_bytes - byte_size(prefix) - 2)

      true ->
        "bwpc:h:" <> hash(prefix <> body, @max_key_bytes - 7)
    end
  end

  @doc "The longest key `key/4` returns, in bytes."
  @spec max_key_bytes() :: pos_integer()
  def max_key_bytes, do: @max_key_bytes

  @doc """
  Builds a stable prompt-cache key from keyword options.
  """
  @spec key(keyword() | map()) :: String.t()
  def key(opts) when is_list(opts) or is_map(opts) do
    key(
      option(opts, :scope, "default"),
      option(opts, :provider_model, "unknown"),
      option(opts, :static_prompt, ""),
      version: option(opts, :version, @default_version)
    )
  end

  @doc "Returns the provider-prefixed model identifier used in cache keys."
  @spec provider_model(term()) :: String.t()
  def provider_model(model) do
    provider = ModelResolver.get_model_provider(model)
    identifier = ModelResolver.get_model_identifier(model)

    cond do
      is_binary(identifier) and String.contains?(identifier, ":") ->
        identifier

      is_binary(provider) and is_binary(identifier) ->
        "#{provider}:#{identifier}"

      is_binary(identifier) ->
        identifier

      is_binary(provider) ->
        provider

      true ->
        "unknown"
    end
  end

  defp digest(static_prompt), do: hash(static_prompt, @digest_length)

  defp hash(value, length) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
    |> String.slice(0, length)
  end

  defp option(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)
  defp option(opts, key, default) when is_map(opts), do: Map.get(opts, key, default)

  defp sanitize(value, fallback) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_.-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> fallback
      sanitized -> sanitized
    end
  end
end
