defmodule BeamWeaver.PromptCache do
  @moduledoc """
  Helpers for stable provider prompt-cache keys.
  """

  alias BeamWeaver.Agent.ModelResolver

  @default_version "v1"
  @digest_length 20

  @doc """
  Builds a stable prompt-cache key from a scope, provider/model id, and static prompt.
  """
  @spec key(term(), term(), String.t() | nil, keyword()) :: String.t()
  def key(scope, provider_model, static_prompt, opts \\ []) do
    version = Keyword.get(opts, :version, @default_version)
    digest = digest(static_prompt || "")

    [
      "bwpc",
      sanitize(version, "v1"),
      sanitize(scope, "default"),
      sanitize(provider_model, "unknown"),
      digest
    ]
    |> Enum.join(":")
  end

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

  defp digest(static_prompt) do
    static_prompt
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
    |> String.slice(0, @digest_length)
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
