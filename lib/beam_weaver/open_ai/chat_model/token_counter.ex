defmodule BeamWeaver.OpenAI.ChatModel.TokenCounter do
  @moduledoc false

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.LanguageModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.Utils, as: MessageUtils
  alias BeamWeaver.Tokenizer

  @spec count(term(), term(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count(model, input, opts) do
    case model.tokenizer || BeamWeaver.Models.tokenizer_for(model) do
      {:ok, tokenizer} ->
        count_openai_tokens(tokenizer, input, opts)

      tokenizer when not is_nil(tokenizer) ->
        count_openai_tokens(tokenizer, input, opts)

      _missing ->
        count_openai_tokens_approximately(input, opts)
    end
  end

  defp count_openai_tokens(tokenizer, input, opts) when is_binary(input),
    do: Tokenizer.count_tokens(tokenizer, input, opts)

  defp count_openai_tokens(tokenizer, %Message{} = message, opts),
    do: count_openai_tokens(tokenizer, [message], opts)

  defp count_openai_tokens(tokenizer, input, opts) do
    with {:ok, messages} <- MessageUtils.normalize(input),
         {:ok, message_count} <- count_tokenized_messages(tokenizer, messages, opts),
         {:ok, tool_count} <- count_tokenized_tools(tokenizer, Keyword.get(opts, :tools), opts) do
      {:ok, message_count + tool_count}
    end
  end

  defp count_openai_tokens_approximately(input, opts) when is_list(input),
    do: MessageUtils.count_tokens_approximately(input, opts)

  defp count_openai_tokens_approximately(%Message{} = message, opts),
    do: MessageUtils.count_tokens_approximately([message], opts)

  defp count_openai_tokens_approximately(input, _opts),
    do: {:ok, LanguageModel.count_tokens_approximately(input)}

  defp count_tokenized_messages(tokenizer, messages, opts) do
    Enum.reduce_while(messages, {:ok, 0}, fn message, {:ok, acc} ->
      case count_tokenized_message(tokenizer, message, opts) do
        {:ok, count} -> {:cont, {:ok, acc + count}}
        {:error, %BeamWeaver.Core.Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp count_tokenized_message(tokenizer, %Message{} = message, opts) do
    with {:ok, role_count} <-
           Tokenizer.count_tokens(tokenizer, Atom.to_string(message.role), opts),
         {:ok, content_count} <- count_tokenized_content(tokenizer, message.content, opts),
         {:ok, name_count} <- count_optional_text(tokenizer, message.name, opts),
         {:ok, tool_call_id_count} <- count_optional_text(tokenizer, message.tool_call_id, opts),
         {:ok, tool_call_count} <- count_tokenized_term(tokenizer, message.tool_calls, opts),
         {:ok, server_call_count} <-
           count_tokenized_term(tokenizer, message.server_tool_calls, opts),
         {:ok, server_result_count} <-
           count_tokenized_term(tokenizer, message.server_tool_results, opts) do
      {:ok,
       Keyword.get(opts, :tokens_per_message, 3) + role_count + content_count + name_count +
         tool_call_id_count + tool_call_count + server_call_count + server_result_count}
    end
  end

  defp count_tokenized_content(tokenizer, content, opts) when is_binary(content),
    do: Tokenizer.count_tokens(tokenizer, content, opts)

  defp count_tokenized_content(tokenizer, content, opts) when is_list(content) do
    Enum.reduce_while(content, {:ok, 0}, fn block, {:ok, acc} ->
      case count_content_block(tokenizer, block, opts) do
        {:ok, count} -> {:cont, {:ok, acc + count}}
        {:error, %BeamWeaver.Core.Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp count_content_block(tokenizer, %ContentBlock.Text{text: text}, opts),
    do: Tokenizer.count_tokens(tokenizer, text || "", opts)

  defp count_content_block(tokenizer, %ContentBlock.PlainText{text: text}, opts),
    do: Tokenizer.count_tokens(tokenizer, text || "", opts)

  defp count_content_block(_tokenizer, %ContentBlock.Image{}, opts),
    do: {:ok, Keyword.get(opts, :tokens_per_image, 85)}

  defp count_content_block(_tokenizer, %ContentBlock.Audio{}, opts),
    do: {:ok, Keyword.get(opts, :tokens_per_audio, 120)}

  defp count_content_block(_tokenizer, %ContentBlock.Video{}, opts),
    do: {:ok, Keyword.get(opts, :tokens_per_video, Keyword.get(opts, :tokens_per_image, 85))}

  defp count_content_block(tokenizer, %ContentBlock.File{} = block, opts),
    do: count_tokenized_term(tokenizer, block, opts)

  defp count_content_block(tokenizer, %ContentBlock.Reasoning{reasoning: text}, opts),
    do: Tokenizer.count_tokens(tokenizer, text || "", opts)

  defp count_content_block(tokenizer, %ContentBlock.Citation{} = block, opts),
    do: count_tokenized_term(tokenizer, block, opts)

  defp count_content_block(tokenizer, %ContentBlock.ToolResult{} = block, opts),
    do: count_tokenized_term(tokenizer, block, opts)

  defp count_content_block(tokenizer, %ContentBlock.Unknown{} = block, opts),
    do: count_tokenized_term(tokenizer, block, opts)

  defp count_content_block(tokenizer, %{type: type, text: text}, opts)
       when type in [:text, :plain_text, :input_text, :output_text],
       do: Tokenizer.count_tokens(tokenizer, text || "", opts)

  defp count_content_block(tokenizer, %{type: type, content: content}, opts)
       when type in [:text, :plain_text, :input_text, :output_text],
       do: Tokenizer.count_tokens(tokenizer, content || "", opts)

  defp count_content_block(_tokenizer, %{type: type}, opts)
       when type in [:image, :image_url, :input_image],
       do: {:ok, Keyword.get(opts, :tokens_per_image, 85)}

  defp count_content_block(_tokenizer, %{type: type}, opts)
       when type in [:audio, :input_audio],
       do: {:ok, Keyword.get(opts, :tokens_per_audio, 120)}

  defp count_content_block(tokenizer, block, opts) when is_map(block),
    do: count_tokenized_term(tokenizer, block, opts)

  defp count_content_block(tokenizer, block, opts),
    do: count_tokenized_term(tokenizer, block, opts)

  defp count_tokenized_tools(_tokenizer, nil, _opts), do: {:ok, 0}

  defp count_tokenized_tools(tokenizer, tools, opts),
    do: count_tokenized_term(tokenizer, tools, opts)

  defp count_tokenized_term(_tokenizer, value, _opts) when value in [nil, [], %{}], do: {:ok, 0}

  defp count_tokenized_term(tokenizer, value, opts) do
    text =
      case BeamWeaver.JSON.encode(value) do
        {:ok, json} -> json
        {:error, _reason} -> inspect(value)
      end

    Tokenizer.count_tokens(tokenizer, text, opts)
  end

  defp count_optional_text(_tokenizer, nil, _opts), do: {:ok, 0}

  defp count_optional_text(tokenizer, value, opts) do
    with {:ok, count} <- Tokenizer.count_tokens(tokenizer, to_string(value), opts) do
      {:ok, count + Keyword.get(opts, :tokens_per_name, 1)}
    end
  end
end
