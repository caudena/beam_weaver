defmodule BeamWeaver.Examples.Support do
  @moduledoc false

  alias BeamWeaver.Config
  alias BeamWeaver.Models

  @live_model_timeout 60_000

  def model do
    case Models.init_chat_model(model_id(), model_opts()) do
      {:ok, model} -> model
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  def model_id, do: Config.get([:examples, :model]) || "openai:gpt-5.4-mini"

  def model_opts do
    [
      api_key: api_key(),
      max_tokens: 2048,
      max_output_tokens: 2048,
      timeout: @live_model_timeout
    ]
    |> maybe_put_zai_defaults()
  end

  def api_key do
    key = Config.get([:examples, :api_keys], %{}) |> Map.get(provider())

    if key in [nil, ""] do
      raise ArgumentError, "set #{String.upcase(provider())}_API_KEY to run the examples (model: #{model_id()})"
    end

    key
  end

  defp provider, do: model_id() |> String.split(":", parts: 2) |> hd()

  defp maybe_put_zai_defaults(opts) do
    if provider() == "zai" do
      Keyword.merge(opts, thinking: %{type: "disabled"}, reasoning_effort: "none")
    else
      opts
    end
  end
end
