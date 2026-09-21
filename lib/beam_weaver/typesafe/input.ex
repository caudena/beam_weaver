defmodule BeamWeaver.TypeSafe.Input do
  @moduledoc false

  alias BeamWeaver.Core.{ContentBlock, Error, Message}
  alias BeamWeaver.Core.Messages.ToolCall
  alias BeamWeaver.Provider.Validation
  alias BeamWeaver.Result
  alias BeamWeaver.TypeSafe.Question

  def normalize(input, opts \\ []) do
    with {:ok, _bounds} <- Validation.measure(input, opts),
         {:ok, normalized} <- json(input),
         %{"state" => state, "questions" => questions} <- normalized,
         true <- (is_binary(state) or is_map(state) or is_list(state)) and not is_struct(state),
         true <- is_map(questions) and map_size(questions) > 0,
         {:ok, _questions} <- Result.traverse(questions, &validate_question/1) do
      {:ok, Map.take(normalized, ["state", "questions"])}
    else
      {:error, error} -> {:error, error}
      _ -> invalid("input requires state (text, object or array) and a non-empty questions map")
    end
  end

  def json(%Question{} = question), do: question |> Map.from_struct() |> json()

  def json(%Message{} = message) do
    with {:ok, content} <- message_content(message.content),
         {:ok, calls} <- json(message.tool_calls) do
      json(%{
        role: message.role,
        content: content,
        name: message.name,
        tool_call_id: message.tool_call_id,
        tool_calls: calls
      })
    end
  end

  def json(%ToolCall{} = call), do: call |> Map.from_struct() |> Map.take([:id, :name, :args]) |> json()
  def json(%_{}), do: invalid("state contains an unsupported struct; project it to JSON data first")

  def json(map) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, key} <- json_key(key),
           false <- Map.has_key?(acc, key),
           {:ok, value} <- json(value) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        true -> {:halt, invalid("input contains colliding JSON keys")}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def json(list) when is_list(list), do: Result.traverse(list, &json/1)
  def json(value) when is_nil(value) or is_boolean(value) or is_number(value), do: {:ok, value}

  def json(value) when is_binary(value) do
    if String.valid?(value), do: {:ok, value}, else: invalid("input must be valid UTF-8")
  end

  def json(value) when is_atom(value), do: {:ok, Atom.to_string(value)}
  def json(_value), do: invalid("input contains a non-JSON value")

  defp json_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp json_key(key) when is_binary(key), do: json(key)
  defp json_key(_key), do: invalid("JSON object keys must be strings or atoms")

  defp message_content(content) when is_binary(content), do: json(content)
  defp message_content(content) when is_list(content), do: Result.traverse(content, &text_block/1)
  defp message_content(_content), do: invalid("Jev messages must contain text")

  defp text_block(%ContentBlock.Text{text: text}), do: json(%{type: :text, text: text})
  defp text_block(%ContentBlock.PlainText{text: text}), do: json(%{type: :text, text: text})
  defp text_block(text) when is_binary(text), do: json(text)

  defp text_block(%{type: type, text: text}) when type in [:text, :plain_text, "text", "plain_text"],
    do: json(%{type: :text, text: text})

  defp text_block(%{"type" => type, "text" => text}) when type in ["text", "plain_text"],
    do: json(%{type: :text, text: text})

  defp text_block(_block), do: invalid("Jev supports text only; project non-text message blocks explicitly")

  defp validate_question({id, %{"type" => type} = question}) when id != "" and is_binary(type) do
    instructions = Map.get(question, "instructions")
    criteria = Map.get(question, "criteria")

    if entry?(instructions) and valid_criteria?(type, criteria),
      do: {:ok, question},
      else: invalid("invalid #{type} question", %{question_id: id})
  end

  defp validate_question({id, _}), do: invalid("question requires a supported type", %{question_id: id})

  defp entry?(value), do: is_nil(value) or is_binary(value) or is_map(value) or is_list(value)

  defp valid_criteria?("choice", criteria) when is_map(criteria) and map_size(criteria) in 1..255,
    do: Enum.all?(criteria, fn {key, value} -> key != "" and entry?(value) end)

  defp valid_criteria?("score", criteria) when is_list(criteria),
    do: length(criteria) in 2..10 and Enum.all?(criteria, &(not is_nil(&1) and entry?(&1)))

  defp valid_criteria?("noul", nil), do: true

  defp valid_criteria?("noul", criteria) when is_map(criteria),
    do: Enum.all?(criteria, fn {key, value} -> key in ["true", "false"] and entry?(value) end)

  defp valid_criteria?(_type, _criteria), do: false
  defp invalid(message, details \\ %{}), do: {:error, Error.new(:invalid_decision_input, message, details)}
end
