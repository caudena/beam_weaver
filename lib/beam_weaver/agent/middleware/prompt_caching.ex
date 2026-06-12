defmodule BeamWeaver.Agent.Middleware.PromptCaching do
  @moduledoc "Applies Anthropic prompt-cache control to the static system prompt."

  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Anthropic.Middleware.PromptCaching, as: AnthropicPromptCaching
  alias BeamWeaver.Core.Message

  defstruct helper: AnthropicPromptCaching.new()

  def new(opts \\ []),
    do: %__MODULE__{helper: AnthropicPromptCaching.new(opts)}

  @impl true
  def name(_middleware), do: :deepagents_prompt_caching

  def wrap_model_call(%__MODULE__{} = middleware, %ModelRequest{} = request, handler) do
    if anthropic_model?(request.model) do
      cache_control = middleware.helper.cache_control

      request
      |> ModelRequest.override(system_message: cache_system_message(request.system_message, cache_control))
      |> handler.()
    else
      handler.(request)
    end
  end

  defp anthropic_model?(%BeamWeaver.Anthropic.ChatModel{}), do: true
  defp anthropic_model?(_model), do: false

  defp cache_system_message(nil, _cache_control), do: nil

  defp cache_system_message(%Message{role: :system, content: content} = message, cache_control) do
    %{message | content: cache_content(content, cache_control)}
  end

  defp cache_system_message(messages, cache_control) when is_list(messages) do
    case Enum.reverse(messages) do
      [] ->
        []

      [%Message{role: :system} = last | rest] ->
        Enum.reverse([cache_system_message(last, cache_control) | rest])

      _other ->
        messages
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

  defp put_cache_control(block, cache_control) when is_map(block),
    do: Map.put(block, :cache_control, cache_control)

  defp put_cache_control(block, _cache_control), do: block

  defp cached_text_block(text, cache_control),
    do: %{type: :text, text: text, cache_control: cache_control}
end
