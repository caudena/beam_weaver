defmodule BeamWeaver.Examples.Support do
  @moduledoc false

  alias BeamWeaver.Config
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Models

  @live_model_timeout 60_000
  @prompt_cache_version "v1"

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

  def prompt_cache_key(scope, static_prompt) do
    digest =
      static_prompt
      |> then(fn prompt -> :crypto.hash(:sha256, prompt) end)
      |> Base.url_encode64(padding: false)
      |> String.slice(0, 20)

    scope_slug =
      scope
      |> to_string()
      |> String.replace(~r/[^A-Za-z0-9_.-]+/, "-")

    model_slug =
      model_id()
      |> String.replace(~r/[^A-Za-z0-9_.-]+/, "-")
      |> String.slice(0, 16)

    "bwpc:#{@prompt_cache_version}:#{scope_slug}:#{model_slug}:#{digest}"
  end

  def prompt_cache_messages(%BeamWeaver.Anthropic.ChatModel{}, static_prompt, messages) do
    [
      Message.system([
        %{
          type: :text,
          text: static_prompt,
          cache_control: %{type: :ephemeral}
        }
      ])
      | messages
    ]
  end

  def prompt_cache_messages(_model, static_prompt, messages) do
    [Message.system(static_prompt) | messages]
  end

  def prompt_cache_opts(model, scope, static_prompt) do
    key = prompt_cache_key(scope, static_prompt)

    case model do
      %BeamWeaver.OpenAI.ChatModel{} ->
        [prompt_cache_key: key, prompt_cache_retention: :in_memory]

      %BeamWeaver.XAI.ChatModel{} ->
        [prompt_cache_key: key]

      %BeamWeaver.Moonshot.ChatModel{} ->
        [prompt_cache_key: key]

      %BeamWeaver.Anthropic.ChatModel{} ->
        []

      %BeamWeaver.Google.ChatModel{} ->
        case Config.get([:examples, :cached_content]) do
          nil -> []
          cached_content -> [cached_content: cached_content]
        end

      _model ->
        []
    end
  end

  def cache_read_tokens(%Message{usage_metadata: metadata}) when is_map(metadata) do
    get_in(metadata, [:input_token_details, :cache_read]) || 0
  end

  def cache_read_tokens(_message), do: 0

  defp maybe_put_zai_defaults(opts) do
    if provider() == "zai" do
      Keyword.merge(opts, thinking: %{type: "disabled"}, reasoning_effort: "none")
    else
      opts
    end
  end
end
