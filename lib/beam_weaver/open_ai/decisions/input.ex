defmodule BeamWeaver.OpenAI.Decisions.Input do
  @moduledoc false

  # The `input` and `questions` of a Decisions API request. A string goes as
  # it is, and user messages as user messages. Any other state, such as a
  # conversation or a map, goes as JSON text in one user message, with the
  # images of its messages as image parts where they appear in the text.

  alias BeamWeaver.Core.{Error, Message}
  alias BeamWeaver.Core.Messages.ToolCall
  alias BeamWeaver.MapAccess
  alias BeamWeaver.OpenAI.Decisions.Question
  alias BeamWeaver.OpenAI.Messages.Request
  alias BeamWeaver.Result

  @max_questions 200
  @max_choices 255
  @max_images 128

  def request(input) when is_map(input) do
    state = MapAccess.get(input, :state)
    questions = MapAccess.get(input, :questions)

    with :ok <- check_questions(questions),
         {:ok, questions} <- Result.traverse(questions, fn {name, question} -> question(name, question) end),
         {:ok, input} <- input(state),
         :ok <- check_images(input) do
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
         :ok <- check_instructions(instructions, name),
         {:ok, fields} <- fields(question, name) do
      {:ok, Map.merge(%{"type" => Atom.to_string(type), "name" => name, "instructions" => instructions}, fields)}
    end
  end

  defp question(name, _question),
    do: invalid("each question must be a BeamWeaver.OpenAI.Decisions.Question", %{question: name})

  defp name(name) when is_binary(name) and name != "", do: {:ok, name}
  defp name(name) when is_atom(name) and not is_nil(name) and not is_boolean(name), do: {:ok, Atom.to_string(name)}
  defp name(name), do: invalid("question names must be strings or atoms", %{question: name})

  defp check_instructions(instructions, name) do
    if is_binary(instructions) and String.trim(instructions) != "",
      do: :ok,
      else: invalid("a question's instructions must be a non-empty string", %{question: name})
  end

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
      value -> {:ok, put_present(%{"value" => value}, "description", description)}
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
        {:ok, put_present(%{"label" => label}, "description", description)}

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

  defp input(state) do
    if user_messages?(state),
      do: Result.traverse(List.wrap(state), &user_message/1),
      else: json_message(state)
  end

  defp user_messages?(%Message{role: :user}), do: true
  defp user_messages?([_ | _] = state), do: Enum.all?(state, &match?(%Message{role: :user}, &1))
  defp user_messages?(_state), do: false

  defp user_message(message) do
    case Request.to_responses_input([message]) do
      {:ok, [%{"type" => "message", "content" => text}]} when is_binary(text) ->
        {:ok, %{"role" => "user", "content" => text}}

      {:ok, [%{"type" => "message", "content" => parts}]} ->
        with {:ok, parts} <- Result.traverse(parts, &user_part/1), do: {:ok, %{"role" => "user", "content" => parts}}

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

  # Each image in a message becomes a numbered marker in the JSON text, which
  # is then split at the markers to put the images there.
  defp json_message(state) do
    marker = "bw-image-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    with {:ok, data, images} <- json(state, marker, []) do
      [text | rest] = data |> BeamWeaver.JSON.encode!() |> String.split(marker <> "-")
      images = images |> Enum.reverse() |> List.to_tuple()

      parts =
        Enum.flat_map(rest, fn segment ->
          {index, text} = Integer.parse(segment)
          [elem(images, index) | text_part(text)]
        end)

      {:ok, [%{"role" => "user", "content" => text_part(text) ++ parts}]}
    end
  end

  defp text_part(""), do: []
  defp text_part(text), do: [%{"type" => "input_text", "text" => text}]

  defp json(%Message{} = message, marker, images) do
    with {:ok, content, images} <- json_content(message.content, marker, images),
         {:ok, calls, images} <- json(message.tool_calls, marker, images) do
      message =
        %{"role" => Atom.to_string(message.role), "content" => content}
        |> put_present("name", message.name)
        |> put_present("tool_call_id", message.tool_call_id)
        |> put_present("tool_calls", calls)

      {:ok, message, images}
    end
  end

  defp json(%ToolCall{} = call, marker, images) do
    with {:ok, args, images} <- json(call.args, marker, images),
         do: {:ok, %{"id" => call.id, "name" => call.name, "args" => args}, images}
  end

  defp json(%_{} = struct, _marker, _images),
    do:
      invalid("state contains a struct OpenAI Decisions can't send; convert it to JSON data first", %{
        struct: struct.__struct__
      })

  defp json(map, marker, images) when is_map(map) do
    with {:ok, entries, images} <- json_all(map, marker, images, &json_entry/3), do: {:ok, Map.new(entries), images}
  end

  defp json(list, marker, images) when is_list(list), do: json_all(list, marker, images, &json/3)

  defp json(value, _marker, images) when is_nil(value) or is_boolean(value) or is_number(value),
    do: {:ok, value, images}

  defp json(value, _marker, images) when is_atom(value), do: {:ok, Atom.to_string(value), images}

  defp json(value, _marker, images) when is_binary(value) do
    if String.valid?(value), do: {:ok, value, images}, else: invalid("state must be valid UTF-8")
  end

  defp json(_value, _marker, _images), do: invalid("state contains a value that isn't JSON data")

  defp json_entry({key, value}, marker, images) when is_binary(key) or is_atom(key) do
    with {:ok, value, images} <- json(value, marker, images), do: {:ok, {to_string(key), value}, images}
  end

  defp json_entry(_entry, _marker, _images), do: invalid("state map keys must be strings or atoms")

  defp json_content(blocks, marker, images) when is_list(blocks), do: json_all(blocks, marker, images, &json_block/3)
  defp json_content(content, marker, images), do: json(content, marker, images)

  defp json_block(text, _marker, images) when is_binary(text), do: {:ok, %{"type" => "text", "text" => text}, images}

  defp json_block(%{type: type, text: text}, _marker, images) when type in [:text, :plain_text] and is_binary(text),
    do: {:ok, %{"type" => "text", "text" => text}, images}

  defp json_block(%{type: type} = block, marker, images) when type in [:image, :image_url] do
    with {:ok, [%{"content" => [part]}]} <- Request.to_responses_input([%Message{role: :user, content: [block]}]),
         {:ok, part} <- user_part(part) do
      {:ok, %{"type" => "text", "text" => "#{marker}-#{length(images)}"}, [part | images]}
    end
  end

  defp json_block(block, _marker, _images) do
    type = if is_map(block), do: Map.get(block, :type)

    invalid("OpenAI Decisions takes text and images in messages; convert other content to text first", %{block: type})
  end

  defp json_all(values, marker, images, fun) do
    values
    |> Enum.reduce_while({:ok, [], images}, fn value, {:ok, acc, images} ->
      case fun.(value, marker, images) do
        {:ok, value, images} -> {:cont, {:ok, [value | acc], images}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values, images} -> {:ok, Enum.reverse(values), images}
      {:error, _error} = error -> error
    end
  end

  defp check_images(input) when is_list(input) do
    count = input |> Enum.flat_map(&List.wrap(&1["content"])) |> Enum.count(&match?(%{"type" => "input_image"}, &1))

    if count <= @max_images,
      do: :ok,
      else: invalid("OpenAI Decisions takes at most #{@max_images} images in a request", %{images: count})
  end

  defp check_images(_text), do: :ok

  defp put_present(map, _key, value) when value in [nil, []], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp invalid(message, details \\ %{}), do: {:error, Error.new(:invalid_decision_input, message, details)}
end
