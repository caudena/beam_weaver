defmodule BeamWeaver.DeepSeek.Vision do
  @moduledoc false

  alias BeamWeaver.DeepSeek.Error
  alias BeamWeaver.Models.ProfileRegistry.DeepSeek

  @image_types ~w(input_image image_url file)
  @details [nil, "low", "high", "original", "auto"]
  @max_inline_bytes 32 * 1024 * 1024
  @max_request_bytes 48 * 1024 * 1024

  def validate_request(body, api) do
    images = image_parts(body, api)

    cond do
      images == [] ->
        :ok

      not DeepSeek.vision_model?(body["model"]) ->
        unsupported(:image, api)

      length(images) > 600 ->
        invalid("DeepSeek accepts at most 600 images per request", api)

      byte_size(BeamWeaver.JSON.encode!(body)) > @max_request_bytes ->
        invalid("DeepSeek image requests must fit within 48 MiB", api)

      true ->
        Enum.reduce_while(images, :ok, fn {part, role}, :ok ->
          case validate_image(part, role, api) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)
    end
  end

  defp image_parts(body, api) do
    key = if api == :responses, do: "input", else: "messages"

    body
    |> Map.get(key, [])
    |> Enum.flat_map(fn item ->
      {parts, role} =
        if item["type"] in ["function_call_output", "custom_tool_call_output"] do
          {item["output"], "tool"}
        else
          {item["content"], item["role"]}
        end

      if is_list(parts) do
        for part <- parts, is_map(part), part["type"] in @image_types, do: {part, role}
      else
        []
      end
    end)
  end

  defp validate_image(part, role, api) do
    roles = if api == :responses, do: ["user", "developer", "tool"], else: ["user", "tool"]
    source = if is_map(part["image_url"]), do: part["image_url"], else: part
    url = source["url"] || source["image_url"] || source["file_data"]
    file_id = source["file_id"]
    feature = if part["type"] == "file", do: :file, else: :image

    cond do
      role not in roles -> invalid("DeepSeek images are not supported in this message role", api)
      not is_nil(url) and not is_nil(file_id) -> invalid("DeepSeek images require one source", api)
      is_binary(file_id) and file_id != "" -> :ok
      source["detail"] not in @details -> invalid("DeepSeek image detail must be low, high, original, or auto", api)
      is_binary(url) -> validate_url(url, feature, api)
      true -> invalid("DeepSeek images require image data, an HTTP URL, or a file_id", api)
    end
  end

  defp validate_url("data:" <> _rest = url, feature, api) do
    case Regex.run(~r{\Adata:image/(?:jpeg|png|gif|webp);base64,(.*)\z}s, url) do
      [_, encoded] ->
        case Base.decode64(encoded) do
          {:ok, bytes} when byte_size(bytes) > 0 and byte_size(bytes) <= @max_inline_bytes -> :ok
          _ -> invalid("DeepSeek inline images require valid base64 and at most 32 MiB per image", api)
        end

      _ ->
        unsupported(feature, api)
    end
  end

  defp validate_url(url, _feature, api) do
    uri = URI.parse(url)

    if byte_size(url) <= 8192 and uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      :ok
    else
      invalid("DeepSeek image URLs must use HTTP(S) and be at most 8192 bytes", api)
    end
  end

  defp unsupported(feature, api) do
    {:error,
     Error.new(:unsupported_feature, "DeepSeek model or content does not support this image input", %{
       provider: :deepseek,
       api: api,
       feature: feature
     })}
  end

  defp invalid(message, api), do: {:error, Error.new(:invalid_request, message, %{provider: :deepseek, api: api})}
end
