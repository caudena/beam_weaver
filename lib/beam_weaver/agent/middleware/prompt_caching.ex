defmodule BeamWeaver.Agent.Middleware.PromptCaching do
  @moduledoc "Applies provider-aware prompt-cache controls to model calls."

  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Anthropic.Middleware.PromptCaching, as: AnthropicPromptCaching
  alias BeamWeaver.Core.Message
  alias BeamWeaver.PromptCache

  defstruct helper: AnthropicPromptCaching.new(), scope: nil, version: "v1"

  def new(opts \\ []) do
    attrs = if is_map(opts), do: opts, else: Map.new(opts)
    cache_control = Map.get(attrs, :cache_control, %{type: :ephemeral})

    %__MODULE__{
      helper: AnthropicPromptCaching.new(cache_control: cache_control),
      scope: Map.get(attrs, :scope),
      version: Map.get(attrs, :version, "v1")
    }
  end

  @impl true
  def name(_middleware), do: :deepagents_prompt_caching

  @impl true
  def wrap_model_call(%__MODULE__{} = middleware, %ModelRequest{} = request, handler) do
    request =
      if match?(%BeamWeaver.Anthropic.ChatModel{}, request.model) do
        cache_control = middleware.helper.cache_control
        ModelRequest.override(request, system_message: cache_system_message(request.system_message, cache_control))
      else
        request
      end

    case provider_cache_opts(request, middleware) do
      [] -> handler.(request)
      opts -> request |> ModelRequest.override(model_opts: Keyword.merge(opts, request.model_opts || [])) |> handler.()
    end
  end

  defp provider_cache_opts(%ModelRequest{model: %module{}} = request, middleware)
       when module in [
              BeamWeaver.OpenAI.ChatModel,
              BeamWeaver.OpenAI.ChatCompletionsModel,
              BeamWeaver.OpenAI.ResponsesModel,
              BeamWeaver.Moonshot.ChatModel
            ],
       do: [prompt_cache_key: cache_key(request, middleware)]

  defp provider_cache_opts(%ModelRequest{model: %BeamWeaver.XAI.ChatModel{}} = request, middleware) do
    key = cache_key(request, middleware)
    [prompt_cache_key: key, x_grok_conv_id: key]
  end

  defp provider_cache_opts(%ModelRequest{model: %BeamWeaver.XAI.ChatCompletionsModel{}} = request, middleware),
    do: [x_grok_conv_id: cache_key(request, middleware)]

  defp provider_cache_opts(_request, _middleware), do: []

  defp cache_key(%ModelRequest{} = request, %__MODULE__{} = middleware) do
    PromptCache.key(
      middleware.scope || default_scope(request.runtime),
      PromptCache.provider_model(request.model),
      ModelRequest.system_prompt(request) || "",
      version: middleware.version
    )
  end

  defp default_scope(%{graph_name: graph_name}) when graph_name not in [nil, ""], do: graph_name
  defp default_scope(%{node: node}) when node not in [nil, ""], do: node
  defp default_scope(_runtime), do: "agent"

  defp cache_system_message(%Message{role: :system, content: content} = message, cache_control) do
    %{message | content: cache_content(content, cache_control)}
  end

  defp cache_system_message(messages, cache_control) when is_list(messages) do
    case Enum.reverse(messages) do
      [%Message{role: :system} = last | rest] -> Enum.reverse([cache_system_message(last, cache_control) | rest])
      _other -> messages
    end
  end

  defp cache_system_message(other, _cache_control), do: other

  defp cache_content(content, cache_control) when is_binary(content),
    do: [cached_text_block(content, cache_control)]

  defp cache_content(content, cache_control) when is_list(content) do
    index =
      content
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn
        {%{type: :text}, index} -> index
        {%{type: :plain_text}, index} -> index
        {text, index} when is_binary(text) -> index
        _other -> nil
      end)

    if is_nil(index) do
      content ++ [cached_text_block("", cache_control)]
    else
      List.update_at(content, index, &put_cache_control(&1, cache_control))
    end
  end

  defp cache_content(content, cache_control),
    do: [cached_text_block(to_string(content), cache_control)]

  defp put_cache_control(text, cache_control) when is_binary(text),
    do: cached_text_block(text, cache_control)

  defp put_cache_control(block, cache_control), do: Map.put(block, :cache_control, cache_control)

  defp cached_text_block(text, cache_control),
    do: %{type: :text, text: text, cache_control: cache_control}
end
