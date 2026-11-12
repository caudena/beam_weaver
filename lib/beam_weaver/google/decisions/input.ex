defmodule BeamWeaver.Google.Decisions.Input do
  @moduledoc false

  alias BeamWeaver.Core.{ContentBlock, Error, Message}
  alias BeamWeaver.Core.DecisionModel.State
  alias BeamWeaver.Google.Decisions.Question
  alias BeamWeaver.{MapAccess, MapShape, Result}

  @media_types %{image: "image", audio: "audio", video: "video", file: "document", document: "document"}

  def request(input) when is_map(input) do
    with {:ok, state} <- state(MapAccess.get(input, :state)),
         {:ok, questions} <- questions(MapAccess.get(input, :questions)) do
      {:ok, %{"input" => state, "questions" => questions}}
    end
  end

  def request(_input), do: invalid("Gemini Decisions requires state and questions")

  def checked(%Question{} = question) do
    with {:ok, _body} <- question(question), do: {:ok, question}
  end

  defp questions(questions) when is_map(questions) and map_size(questions) in 1..1_000 do
    with {:ok, entries} <-
           Result.traverse(questions, fn {key, value} ->
             with {:ok, name} <- question_name(key),
                  {:ok, question} <- question(value),
                  do: {:ok, {name, question}}
           end),
         encoded = Map.new(entries),
         true <- map_size(encoded) == map_size(questions) do
      {:ok, encoded}
    else
      false -> invalid("Gemini Decisions question IDs must be unique")
      {:error, _} = error -> error
    end
  end

  defp questions(_), do: invalid("Gemini Decisions takes 1 to 1000 named questions")

  defp question_name(name) when is_atom(name) and not is_nil(name), do: question_name(Atom.to_string(name))

  defp question_name(name) when is_binary(name) do
    if Regex.match?(~r/\A[A-Za-z0-9_-]{1,64}\z/, name),
      do: {:ok, name},
      else: invalid("Invalid Gemini Decisions question ID")
  end

  defp question_name(_name), do: invalid("Invalid Gemini Decisions question ID")

  defp question(%Question{type: type, instructions: instructions, criteria: criteria})
       when type in [:noul, :choice, :score] and is_binary(instructions) do
    with true <- String.valid?(instructions) and String.trim(instructions) != "",
         {:ok, criteria} <- criteria(type, criteria) do
      {:ok,
       %{"type" => Atom.to_string(type), "instructions" => instructions}
       |> MapShape.put_present("criteria", criteria)}
    else
      false -> invalid("Gemini Decisions question instructions must be non-empty text")
      {:error, _} = error -> error
    end
  end

  defp question(_), do: invalid("Each question must be a Gemini Decisions question with text instructions")

  defp criteria(:noul, nil), do: {:ok, nil}

  defp criteria(:noul, map) when is_map(map) do
    entries = MapAccess.normalize_keys(map, [:true_description, :false_description])

    if Enum.all?(entries, fn {key, value} ->
         key in [:true_description, :false_description] and is_binary(value)
       end),
       do: {:ok, MapShape.stringify_keys(entries)},
       else: invalid("Noul criteria take true_description and false_description strings")
  end

  defp criteria(:choice, options) when is_map(options) and map_size(options) in 2..255 do
    if Enum.all?(options, fn {key, value} -> option_key?(key) and is_binary(value) end) do
      encoded = MapShape.stringify_keys(options)

      if map_size(encoded) == map_size(options),
        do: {:ok, encoded},
        else: invalid("Choice options must have unique names")
    else
      invalid("Choice criteria take option names mapped to text descriptions")
    end
  end

  defp criteria(:score, levels) when is_list(levels) and length(levels) in 2..255 do
    if Enum.all?(levels, &(is_binary(&1) and String.valid?(&1) and String.trim(&1) != "")),
      do: {:ok, levels},
      else: invalid("Score criteria take non-empty descriptions in order")
  end

  defp criteria(type, _), do: invalid("Invalid Gemini Decisions criteria", %{question_type: type})

  defp option_key?(key) when is_atom(key) and not is_nil(key), do: option_key?(Atom.to_string(key))

  defp option_key?(key) when is_binary(key) and byte_size(key) in 1..512,
    do:
      String.valid?(key) and String.length(key) <= 128 and key == String.trim(key) and
        not Regex.match?(~r/[[:cntrl:]\p{Zl}\p{Zp}]|[^\S ]/u, key)

  defp option_key?(_), do: false

  defp state(nil), do: invalid("Gemini Decisions input cannot be empty")
  defp state(""), do: invalid("Gemini Decisions input cannot be empty")
  defp state([]), do: invalid("Gemini Decisions input cannot be empty")

  defp state(text) when is_binary(text) do
    if String.valid?(text), do: {:ok, text}, else: invalid("Gemini Decisions input must be UTF-8")
  end

  defp state(%Message{role: :user, content: content}), do: state(content)
  defp state(%ContentBlock.Unknown{value: value}) when is_map(value), do: part(value)
  defp state(%{type: type} = block) when is_map_key(@media_types, type) or type in [:text, :plain_text], do: part(block)
  defp state(%{"type" => type} = block) when type in ["text", "image", "audio", "video", "document"], do: part(block)

  defp state([_ | _] = values) do
    if Enum.all?(values, &content_item?/1),
      do: Result.traverse(values, &part/1),
      else: json_state(values)
  end

  defp state(value), do: json_state(value)

  defp content_item?(%ContentBlock.Unknown{}), do: true
  defp content_item?(%{type: type}), do: is_map_key(@media_types, type) or type in [:text, :plain_text]
  defp content_item?(%{"type" => type}), do: type in ["text", "image", "audio", "video", "document"]
  defp content_item?(value), do: is_binary(value)

  defp part(%ContentBlock.Unknown{value: value}) when is_map(value), do: part(value)
  defp part(text) when is_binary(text), do: part(%{"type" => "text", "text" => text})
  defp part(%{type: type, text: text}) when type in [:text, :plain_text], do: part(text)

  defp part(%{"type" => "text", "text" => text}) when is_binary(text) do
    if String.valid?(text), do: {:ok, %{"type" => "text", "text" => text}}, else: invalid("Text must be UTF-8")
  end

  defp part(%{type: type} = block) when is_map_key(@media_types, type) do
    metadata = Map.get(block, :metadata) || %{}

    %{
      "type" => Map.fetch!(@media_types, type),
      "mime_type" => Map.get(block, :mime_type),
      "data" => Map.get(block, :data),
      "uri" => Map.get(block, :file_id) || Map.get(block, :url) || Map.get(block, :uri)
    }
    |> MapShape.put_present("resolution", MapAccess.get(metadata, :resolution) || Map.get(block, :resolution))
    |> part()
  end

  defp part(%{"type" => type, "mime_type" => mime} = block)
       when type in ["image", "audio", "video", "document"] and is_binary(mime) do
    media = Map.take(block, ["type", "mime_type", "resolution"])

    case {block["data"], block["uri"]} do
      {data, nil} when is_binary(data) and byte_size(data) > 0 ->
        {:ok, Map.put(media, "data", data)}

      {nil, "https://" <> _ = uri} ->
        {:ok, Map.put(media, "uri", uri)}

      _ ->
        invalid("Gemini Decisions media needs base64 data or an HTTPS URI")
    end
  end

  defp part(_), do: invalid("Gemini Decisions takes text, image, audio, video and PDF input blocks with a MIME type")

  defp json_state(value) do
    case State.parts(value, &part/1) do
      {:ok, [text]} when is_binary(text) -> {:ok, text}
      {:ok, parts} -> {:ok, Enum.flat_map(parts, &state_part/1)}
      {:error, _} = error -> error
    end
  end

  defp state_part(""), do: []
  defp state_part(text) when is_binary(text), do: [%{"type" => "text", "text" => text}]
  defp state_part(part), do: [part]

  defp invalid(message, details \\ %{}), do: {:error, Error.new(:invalid_decision_input, message, details)}
end
