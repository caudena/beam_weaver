defmodule BeamWeaver.Anthropic do
  @moduledoc """
  Anthropic provider namespace.
  """

  alias BeamWeaver.Anthropic.ChatModel
  alias BeamWeaver.Anthropic.Tools
  alias BeamWeaver.Config

  @doc """
  Builds an Anthropic Messages API chat model.
  """
  @spec chat_model(keyword()) :: ChatModel.t()
  def chat_model(opts \\ []) do
    opts
    |> provider_opts("v1/messages")
    |> put_count_tokens_endpoint()
    |> ChatModel.new()
  end

  @doc """
  Returns Anthropic tool declaration helpers.
  """
  @spec tools() :: module()
  def tools, do: Tools

  defp provider_opts(opts, _endpoint_path) do
    opts
    |> Keyword.put_new(:api_key, Config.get([:anthropic, :api_key]))
  end

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
