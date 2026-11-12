defmodule BeamWeaver.TypeSafe.Input do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.DecisionModel.State
  alias BeamWeaver.MapAccess
  alias BeamWeaver.Provider.Validation
  alias BeamWeaver.Result
  alias BeamWeaver.TypeSafe.Question

  def normalize(input, opts \\ []) do
    with {:ok, _bounds} <- Validation.measure(input, opts),
         {:ok, normalized} <- encode(input, Keyword.get(opts, :images, false)),
         %{"state" => state, "questions" => questions} <- normalized,
         true <- is_binary(state) or is_map(state) or is_list(state),
         true <- is_map(questions) and map_size(questions) > 0,
         {:ok, entries} <- Result.traverse(questions, &validate_question/1),
         :ok <- validate_box_request(entries, normalized["assets"], opts) do
      {:ok, normalized |> Map.take(["state", "assets"]) |> Map.put("questions", Map.new(entries))}
    else
      {:error, error} -> {:error, error}
      _ -> invalid("input requires state (text, object or array) and a non-empty questions map")
    end
  end

  defp encode(input, true) when is_map(input) do
    with {:ok, data, generated} <- State.assets(question_maps(input), &image_asset/1, preserve_message_shape: true),
         {:ok, assets} <- merge_assets(data["assets"], generated) do
      {:ok, put_assets(data, assets)}
    end
  end

  defp encode(input, _images) do
    if is_nil(MapAccess.get(input, :assets)) do
      with {:ok, data} when is_map(data) <- State.json(question_maps(input), preserve_message_shape: true),
           do: {:ok, Map.delete(data, "assets")}
    else
      invalid("Jev image assets require images: true")
    end
  end

  defp question_maps(input) when is_map(input) do
    Enum.reduce([:questions, "questions"], input, fn key, body ->
      Map.replace_lazy(body, key, &question_maps_value/1)
    end)
  end

  defp question_maps(input), do: input

  defp question_maps_value(questions) when is_map(questions) do
    Map.new(questions, fn
      {id, %Question{} = question} -> {id, Map.from_struct(question)}
      pair -> pair
    end)
  end

  defp question_maps_value(questions), do: questions

  defp put_assets(data, assets) when map_size(assets) == 0, do: Map.delete(data, "assets")
  defp put_assets(data, assets), do: Map.put(data, "assets", assets)

  defp image_asset(%{type: type, data: data, mime_type: mime})
       when type in [:image, :image_url] and is_binary(data) and byte_size(data) > 0 and
              mime in ["image/png", "image/jpeg", "image/jpg"] do
    format = if mime == "image/png", do: "png", else: "jpeg"
    {:ok, %{"type" => "image", "data_base64" => data, "format" => format}}
  end

  defp image_asset(_), do: invalid("Jev accepts inline PNG or JPEG image blocks with base64 data")

  defp merge_assets(nil, generated), do: {:ok, generated}

  defp merge_assets(assets, generated) when is_map(assets) do
    if Enum.all?(assets, &valid_asset?/1) and not Enum.any?(generated, &Map.has_key?(assets, elem(&1, 0))) do
      {:ok, Map.merge(assets, generated)}
    else
      invalid("Jev assets must be named inline PNG or JPEG images")
    end
  end

  defp merge_assets(_assets, _generated), do: invalid("Jev assets must be a map of image names to inline image data")

  defp valid_asset?({name, %{"type" => "image", "format" => format, "data_base64" => data} = asset})
       when is_binary(name) and name != "" and format in ["png", "jpeg", "jpg"] and
              is_binary(data) and data != "",
       do: map_size(asset) == 3

  defp valid_asset?(_entry), do: false

  defp validate_box_request(questions, assets, opts) do
    if Enum.any?(questions, fn {_id, question} -> question["type"] == "box" end) do
      cond do
        not Keyword.get(opts, :images, false) ->
          invalid("Jev Box questions require images: true")

        Keyword.get(opts, :model) == "jev-1.13.0" ->
          invalid("Jev Box questions require Jev 1.14 or later")

        not is_map(assets) or map_size(assets) == 0 ->
          invalid("Jev Box questions require an image asset")

        true ->
          :ok
      end
    else
      :ok
    end
  end

  defp validate_question({id, %{"type" => type} = question}) when id != "" and is_binary(type) do
    instructions = Map.get(question, "instructions")
    criteria = Map.get(question, "criteria")

    if entry?(instructions) and valid_criteria?(type, criteria),
      do: {:ok, {id, if(type == "box", do: Map.delete(question, "criteria"), else: question)}},
      else: invalid("invalid #{type} question", %{question_id: id})
  end

  defp validate_question({id, _}), do: invalid("question requires a supported type", %{question_id: id})

  defp entry?(value), do: is_nil(value) or is_binary(value) or is_map(value) or is_list(value)

  defp valid_criteria?("choice", criteria) when is_map(criteria) and map_size(criteria) in 1..255,
    do: Enum.all?(criteria, fn {key, value} -> key != "" and entry?(value) end)

  defp valid_criteria?("score", criteria) when is_list(criteria),
    do: length(criteria) in 2..10 and Enum.all?(criteria, &(not is_nil(&1) and entry?(&1)))

  defp valid_criteria?(type, nil) when type in ["noul", "box"], do: true

  defp valid_criteria?("noul", criteria) when is_map(criteria),
    do: Enum.all?(criteria, fn {key, value} -> key in ["true", "false"] and entry?(value) end)

  defp valid_criteria?(_type, _criteria), do: false
  defp invalid(message, details \\ %{}), do: {:error, Error.new(:invalid_decision_input, message, details)}
end
