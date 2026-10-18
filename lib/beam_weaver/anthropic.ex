defmodule BeamWeaver.Anthropic do
  @moduledoc ~S"""
  Claude Messages, supported native tools, compaction and provider token counting.

  Constructors return configured values; invocation makes the provider request.
  Load credentials into `config :beam_weaver, :anthropic` in your application's
  runtime configuration. Explicit connection options override configured defaults.
  See the [Anthropic guide](providers/anthropic.md) for an executed request, endpoint
  choices, supported options and account/resource requirements.

  Native tool helpers construct declarations. Hosted tools execute at the provider;
  client actions require an application executor. Keep full returned messages
  for continuation and inspect outcomes rather than HTTP success alone.
  """

  alias BeamWeaver.Anthropic.ChatModel
  alias BeamWeaver.Anthropic.Tools
  alias BeamWeaver.Config

  @doc """
  Builds an Anthropic Messages API chat model.

  The API key and `base_url` (the API root, `"https://api.anthropic.com"` by
  default) come from `config :beam_weaver, :anthropic` unless given.
  """
  @spec chat_model(keyword()) :: ChatModel.t()
  def chat_model(opts \\ []) do
    opts
    |> Keyword.put_new(:api_key, Config.get([:anthropic, :api_key]))
    |> Keyword.put_new_lazy(:base_url, fn -> Config.get([:anthropic, :base_url]) end)
    |> put_count_tokens_endpoint()
    |> ChatModel.new()
  end

  @doc """
  Returns Anthropic tool declaration helpers.
  """
  @spec tools() :: module()
  def tools, do: Tools

  defp put_count_tokens_endpoint(opts) do
    case Keyword.get(opts, :endpoint) do
      nil ->
        opts

      endpoint ->
        Keyword.put_new(
          opts,
          :count_tokens_endpoint,
          String.replace(endpoint, ~r{/messages$}, "/messages/count_tokens")
        )
    end
  end
end
