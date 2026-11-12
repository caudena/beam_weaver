defmodule BeamWeaver.OpenAI.Images do
  @moduledoc """
  OpenAI Images API generation and editing with a BeamWeaver generation observation.

  The provider response includes separate image-model token usage. The trace
  records that usage and the requested image model, but never image bytes.
  """

  alias BeamWeaver.OpenAI.Client
  alias BeamWeaver.Provider.Options
  alias BeamWeaver.Tracing
  alias BeamWeaver.Tracing.Runner

  @request_fields [
    :size,
    :complexity,
    :quality,
    :background,
    :output_format,
    :frame_count,
    :frame_duration_ms,
    :svg,
    :output_compression,
    :n,
    :moderation,
    :response_format,
    :safety_identifier,
    :style,
    :user
  ]

  @doc "Generate images and emit the image-model usage as a generation run."
  @spec generate(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def generate(prompt, opts \\ []) when is_binary(prompt) and is_list(opts) do
    run(prompt, opts, "images/generations", [])
  end

  @doc "Edit images supplied as image URLs or uploaded file IDs and trace the resulting usage."
  @spec edit(String.t(), [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def edit(prompt, [_ | _] = images, opts) when is_binary(prompt) and is_list(opts) do
    opts = Keyword.put(opts, :images, images)
    run(prompt, opts, "images/edits", [:images, :mask, :markup])
  end

  defp run(prompt, opts, endpoint_path, extra_fields) do
    model = Keyword.get(opts, :model, "gpt-image-2.5-flare")
    exporter_opts = Keyword.take(opts, [:exporter, :exporter_opts])
    metadata = %{model_provider: "openai", model_name: model, api: "images"}
    body = request_body(model, prompt, opts, @request_fields ++ extra_fields)

    client =
      opts |> Keyword.take([:base_url, :api_key, :organization, :project, :transport, :transport_opts]) |> Client.new()

    endpoint = Keyword.get(opts, :endpoint) || Client.endpoint(client, endpoint_path)

    Runner.run(
      "openai:#{model}:images",
      [kind: :generation, inputs: %{prompt: prompt}, tags: [:model, :openai, :image], metadata: metadata],
      exporter_opts,
      fn -> Client.post_json(client, endpoint, body, timeout: Keyword.get(opts, :timeout, 90_000)) end,
      fn run, result -> finish_run(run, result, metadata, exporter_opts) end
    )
  end

  defp request_body(model, prompt, opts, fields) do
    Enum.reduce(fields, %{"model" => model, "prompt" => prompt}, fn field, body ->
      Options.put_optional(body, Atom.to_string(field), Options.normalize_value(Keyword.get(opts, field)))
    end)
  end

  defp finish_run(run, {:ok, response} = result, metadata, exporter_opts) do
    usage = response["usage"] || %{}
    image_count = response |> Map.get("data", []) |> length()
    metadata = Options.put_optional(metadata, :svg_usage, response["svg_usage"])

    Tracing.finish_run(
      run,
      exporter_opts ++
        [
          usage: usage,
          outputs: %{image_count: image_count},
          metadata: metadata
        ]
    )

    result
  end

  defp finish_run(run, {:error, error} = result, metadata, exporter_opts) do
    Tracing.fail_run(run, error, exporter_opts ++ [metadata: metadata])
    result
  end
end
