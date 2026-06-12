defmodule BeamWeaver.Core.Messages.TokenCounter do
  @moduledoc false

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message

  def count(messages, opts \\ []) when is_list(messages) do
    chars_per_token = Keyword.get(opts, :chars_per_token, 4.0)
    extra_tokens_per_message = Keyword.get(opts, :extra_tokens_per_message, 3.0)
    count_name? = Keyword.get(opts, :count_name, true)
    tokens_per_image = Keyword.get(opts, :tokens_per_image, 85)

    {token_count, scaling} =
      messages
      |> Enum.reduce(
        {tool_token_count(Keyword.get(opts, :tools), chars_per_token), scaling_state()},
        fn message, {token_count, scaling} ->
          {chars, image_tokens} = content_token_parts(message.content, tokens_per_image)

          chars =
            chars
            |> add_role_chars(message)
            |> add_name_chars(message, count_name?)
            |> add_tool_call_chars(message)
            |> add_tool_call_id_chars(message)

          message_tokens = ceil_tokens(chars, chars_per_token) + extra_tokens_per_message
          token_count = token_count + image_tokens + message_tokens
          scaling = update_scaling(scaling, message, token_count)

          {token_count, scaling}
        end
      )

    maybe_scale_token_count(token_count, scaling, opts, messages)
  end

  defp content_token_parts(content, _tokens_per_image) when is_binary(content) do
    {String.length(content), 0}
  end

  defp content_token_parts(content, tokens_per_image) when is_list(content) do
    Enum.reduce(content, {0, 0}, fn
      block, {chars, images} when is_binary(block) ->
        {chars + String.length(block), images}

      %ContentBlock.Text{text: text}, {chars, images} ->
        {chars + String.length(to_string(text || "")), images}

      %ContentBlock.PlainText{text: text}, {chars, images} ->
        {chars + String.length(to_string(text || "")), images}

      %ContentBlock.Image{}, {chars, images} ->
        {chars, images + tokens_per_image}

      block, {chars, images} when is_map(block) ->
        case block_type(block) do
          type when type in [:image, :image_url, :input_image] ->
            {chars, images + tokens_per_image}

          type when type in [:text, :plain_text, :input_text, :output_text] ->
            {chars + String.length(to_string(Map.get(block, :text) || Map.get(block, :content) || "")), images}

          _type ->
            {chars + json_length(block), images}
        end

      block, {chars, images} ->
        {chars + String.length(inspect(block)), images}
    end)
  end

  defp content_token_parts(content, _tokens_per_image), do: {String.length(inspect(content)), 0}

  defp block_type(block), do: Map.get(block, :type)

  defp add_role_chars(chars, %Message{role: role}), do: chars + String.length(role_name(role))

  defp add_name_chars(chars, %Message{name: name}, true) when is_binary(name),
    do: chars + String.length(name)

  defp add_name_chars(chars, _message, _count_name?), do: chars

  defp add_tool_call_chars(chars, %Message{role: :assistant, content: content, tool_calls: calls})
       when is_binary(content) and calls != [] do
    chars + json_length(calls)
  end

  defp add_tool_call_chars(chars, _message), do: chars

  defp add_tool_call_id_chars(chars, %Message{role: :tool, tool_call_id: id}) when is_binary(id),
    do: chars + String.length(id)

  defp add_tool_call_id_chars(chars, _message), do: chars

  defp tool_token_count(nil, _chars_per_token), do: 0.0
  defp tool_token_count([], _chars_per_token), do: 0.0

  defp tool_token_count(tools, chars_per_token) do
    tools
    |> List.wrap()
    |> Enum.map(&json_length/1)
    |> Enum.sum()
    |> ceil_tokens(chars_per_token)
  end

  defp json_length(value) do
    value
    |> BeamWeaver.JSON.encode!()
    |> String.length()
  rescue
    _exception -> value |> inspect() |> String.length()
  end

  defp ceil_tokens(chars, chars_per_token) do
    chars
    |> Kernel./(chars_per_token)
    |> Float.ceil()
  end

  defp scaling_state do
    %{
      ai_model_provider: nil,
      invalid_model_provider?: false,
      last_ai_total_tokens: nil,
      approx_at_last_ai: nil
    }
  end

  defp update_scaling(scaling, %Message{role: :assistant} = message, token_count) do
    provider = metadata_value(message.response_metadata, :model_provider)

    scaling =
      cond do
        is_nil(scaling.ai_model_provider) ->
          %{scaling | ai_model_provider: provider}

        provider != scaling.ai_model_provider ->
          %{scaling | invalid_model_provider?: true}

        true ->
          scaling
      end

    case metadata_value(message.usage_metadata || %{}, :total_tokens) do
      total_tokens when is_integer(total_tokens) ->
        %{scaling | last_ai_total_tokens: total_tokens, approx_at_last_ai: token_count}

      _other ->
        scaling
    end
  end

  defp update_scaling(scaling, _message, _token_count), do: scaling

  defp metadata_value(map, key) when is_map(map), do: Map.get(map, key)

  defp metadata_value(_map, _key), do: nil

  defp maybe_scale_token_count(token_count, scaling, opts, messages) do
    scaled? = Keyword.get(opts, :use_usage_metadata_scaling, false)

    if scaled? and length(messages) > 1 and not scaling.invalid_model_provider? and
         not is_nil(scaling.ai_model_provider) and not is_nil(scaling.last_ai_total_tokens) and
         is_number(scaling.approx_at_last_ai) and scaling.approx_at_last_ai > 0 do
      factor =
        scaling.last_ai_total_tokens
        |> Kernel./(scaling.approx_at_last_ai)
        |> max(1.0)
        |> min(1.25)

      token_count * factor
    else
      token_count
    end
    |> Float.ceil()
    |> trunc()
  end

  defp role_name(:user), do: "user"
  defp role_name(:assistant), do: "assistant"
  defp role_name(:system), do: "system"
  defp role_name(:tool), do: "tool"
end
