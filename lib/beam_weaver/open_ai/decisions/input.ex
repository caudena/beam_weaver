defmodule BeamWeaver.OpenAI.Decisions.Input do
  @moduledoc false

  # The `input` and `questions` of a Decisions API request. A string goes as
  # it is, and user messages as user messages. Any other state, such as a
  # conversation or a map, goes as JSON text in one user message. Use an
  # explicit input_json state to request native structured evidence.

  import BeamWeaver.MapShape, only: [put_optional: 3]

  alias BeamWeaver.Core.{Error, Message}
  alias BeamWeaver.Core.DecisionModel.State
  alias BeamWeaver.MapAccess
  alias BeamWeaver.OpenAI.Decisions.Question
  alias BeamWeaver.OpenAI.Messages.Request
  alias BeamWeaver.Result

  @max_questions 400
  @max_choices 255
  @max_images 128

  def request(input) when is_map(input) do
    state = MapAccess.get(input, :state)
    questions = MapAccess.get(input, :questions)

    with :ok <- check_questions(questions),
         {:ok, questions} <- Result.traverse(questions, fn {name, question} -> question(name, question) end),
         {:ok, input} <- input(state),
         :ok <- check_images(input, questions) do
      {:ok, %{"input" => input, "questions" => questions}}
    end
  end

  def request(_input), do: invalid("input requires state and questions")

  @doc false
  def checked(question) do
    with {:ok, _question} <- question("question", question), do: {:ok, question}
  end

  defp check_questions(questions) when is_map(questions) and map_size(questions) in 1..@max_questions, do: :ok
  defp check_questions(_questions), do: invalid("input requires a map of 1 to #{@max_questions} questions")

  defp question(name, %Question{type: type, instructions: instructions} = question)
       when type in [:predicate, :choice, :score] do
    with {:ok, name} <- name(name),
         {:ok, instructions} <- encode_instructions(instructions, name),
         {:ok, fields} <- fields(question, name) do
      {:ok, Map.merge(%{"type" => Atom.to_string(type), "name" => name, "instructions" => instructions}, fields)}
    end
  end

  defp question(name, _question),
    do: invalid("each question must be a BeamWeaver.OpenAI.Decisions.Question", %{question: name})

  defp name(name) when is_binary(name) and name != "", do: {:ok, name}
  defp name(name) when is_atom(name) and not is_nil(name) and not is_boolean(name), do: {:ok, Atom.to_string(name)}
  defp name(name), do: invalid("question names must be strings or atoms", %{question: name})

  defp encode_instructions(instructions, name) when is_binary(instructions) do
    if String.trim(instructions) != "",
      do: {:ok, instructions},
      else: invalid("a question's instructions must contain text or images", %{question: name})
  end

  defp encode_instructions([_ | _] = instructions, name) do
    with {:ok, message} <- Message.new(:user, instructions),
         {:ok, [_ | _] = parts} <- encode_user_content(message) do
      {:ok, parts}
    else
      {:error, _} = error -> error
      _ -> invalid("a question's instructions must contain text or images", %{question: name})
    end
  end

  defp encode_instructions(_instructions, name),
    do: invalid("a question's instructions must contain text or images", %{question: name})

  defp fields(%Question{type: :predicate}, _name), do: {:ok, %{}}

  defp fields(%Question{type: :choice, choices: choices}, name) when is_map(choices) or is_list(choices) do
    with {:ok, choices} <- Result.traverse(choices, &choice/1),
         true <- length(choices) in 2..@max_choices,
         true <- choices |> Enum.uniq_by(& &1["value"]) |> length() == length(choices) do
      {:ok, %{"choices" => choices}}
    else
      _invalid -> invalid_choices(name)
    end
  end

  defp fields(%Question{type: :choice}, name), do: invalid_choices(name)

  defp fields(%Question{type: :score, levels: [_, _ | _] = levels}, name) do
    case Result.traverse(levels, &level/1) do
      {:ok, levels} -> {:ok, %{"levels" => levels}}
      {:error, _invalid} -> invalid_levels(name)
    end
  end

  defp fields(%Question{type: :score}, name), do: invalid_levels(name)

  defp choice({value, description}) when is_nil(description) or is_binary(description) do
    case choice_value(value) do
      nil -> {:error, :invalid_choice}
      value -> {:ok, put_optional(%{"value" => value}, "description", description)}
    end
  end

  defp choice(_choice), do: {:error, :invalid_choice}

  defp choice_value(value) when is_boolean(value), do: value
  defp choice_value(value) when is_binary(value) and value != "", do: value
  defp choice_value(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp choice_value(_value), do: nil

  defp level(label) when is_binary(label) and label != "", do: {:ok, %{"label" => label}}

  defp level(%{} = level) do
    case {MapAccess.get(level, :label), MapAccess.get(level, :description)} do
      {label, description} when is_binary(label) and label != "" and (is_nil(description) or is_binary(description)) ->
        {:ok, put_optional(%{"label" => label}, "description", description)}

      _invalid ->
        {:error, :invalid_level}
    end
  end

  defp level(_level), do: {:error, :invalid_level}

  defp invalid_choices(name),
    do:
      invalid(
        "a choice question takes 2 to #{@max_choices} distinct choices, each a string or a boolean with a description or nil",
        %{question: name}
      )

  defp invalid_levels(name),
    do: invalid("a score question takes two or more levels, each a label or a map with a label", %{question: name})

  defp input(nil), do: invalid("input requires state")

  defp input(text) when is_binary(text) do
    if String.valid?(text), do: {:ok, text}, else: invalid("state must be valid UTF-8")
  end

  defp input({:input_json, data}) do
    with {:ok, data} <- State.json(data),
         true <- is_map(data) or (is_list(data) and Enum.all?(data, &is_map/1)) do
      {:ok, [%{"role" => "user", "content" => [%{"type" => "input_json", "data" => data}]}]}
    else
      _ -> invalid("OpenAI Decisions input_json takes an object or an array of objects without media blocks")
    end
  end

  defp input(state) do
    if user_messages?(state),
      do: Result.traverse(List.wrap(state), &user_message/1),
      else: json_message(state)
  end

  defp user_messages?(%Message{role: :user}), do: true
  defp user_messages?([_ | _] = state), do: Enum.all?(state, &match?(%Message{role: :user}, &1))
  defp user_messages?(_state), do: false

  defp user_message(message) do
    with {:ok, content} <- encode_user_content(message),
         do: {:ok, %{"role" => "user", "content" => content}}
  end

  defp encode_user_content(message) do
    case Request.to_responses_input([message]) do
      {:ok, [%{"type" => "message", "content" => text}]} when is_binary(text) ->
        {:ok, text}

      {:ok, [%{"type" => "message", "content" => parts}]} when is_list(parts) ->
        Result.traverse(parts, &user_part/1)

      {:ok, _items} ->
        invalid("OpenAI Decisions takes text and images in user messages")

      {:error, _error} = error ->
        error
    end
  end

  defp user_part(%{"type" => "input_text"} = part), do: {:ok, part}

  defp user_part(%{"type" => "input_image"} = part) do
    if image_url?(part["image_url"]),
      do: {:ok, part},
      else: invalid("OpenAI Decisions takes images as data URLs or HTTP(S) URLs, not file IDs")
  end

  defp user_part(%{"type" => type}), do: invalid("OpenAI Decisions takes text and images in messages", %{part: type})

  defp image_url?(url) when is_binary(url), do: String.starts_with?(url, ["data:", "https://", "http://"])
  defp image_url?(_url), do: false

  defp json_message(state) do
    with {:ok, parts} <- State.parts(state, &evidence_image/1) do
      content =
        Enum.flat_map(parts, fn
          "" -> []
          text when is_binary(text) -> [%{"type" => "input_text", "text" => text}]
          part -> [part]
        end)

      {:ok, [%{"role" => "user", "content" => content}]}
    end
  end

  defp evidence_image(%{type: type} = block) when type in [:image, :image_url] do
    case encode_user_content(%Message{role: :user, content: [block]}) do
      {:ok, [%{"type" => "input_image"} = part]} -> {:ok, part}
      {:ok, _content} -> invalid("OpenAI Decisions requires a valid image block")
      {:error, _} = error -> error
    end
  end

  defp evidence_image(block) do
    type = if is_map(block), do: Map.get(block, :type)

    invalid("OpenAI Decisions takes text and images in messages; convert other content to text first", %{block: type})
  end

  defp check_images(input, questions) do
    count =
      Enum.reduce(questions, input_image_count(input), fn question, count ->
        count + image_count(question["instructions"])
      end)

    if count <= @max_images,
      do: :ok,
      else: invalid("OpenAI Decisions takes at most #{@max_images} images in a request", %{images: count})
  end

  defp input_image_count(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn message, count -> count + image_count(message["content"]) end)
  end

  defp input_image_count(_text), do: 0

  defp image_count(parts) when is_list(parts), do: Enum.count(parts, &match?(%{"type" => "input_image"}, &1))
  defp image_count(_text), do: 0

  defp invalid(message, details \\ %{}), do: {:error, Error.new(:invalid_decision_input, message, details)}
end
