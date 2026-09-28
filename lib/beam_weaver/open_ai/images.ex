defmodule BeamWeaver.OpenAI.Images do
  @moduledoc """
  OpenAI Images API generation with a BeamWeaver generation observation.

  The provider response includes separate image-model token usage. The trace
  records that usage and the requested image model, but never image bytes.
  """

  alias BeamWeaver.OpenAI.Client
  alias BeamWeaver.Tracing
  alias BeamWeaver.Tracing.Runner

  @endpoint "https://api.openai.com/v1/images/generations"
  @request_fields [:size, :quality, :background, :output_format, :output_compression, :n]

  @doc "Generate images and emit the image-model usage as a generation run."
  @spec generate(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def generate(prompt, opts \\ []) when is_binary(prompt) and is_list(opts) do
    model = Keyword.get(opts, :model, "gpt-image-2.5-flare")
    endpoint = Keyword.get(opts, :endpoint, @endpoint)
    exporter_opts = Keyword.take(opts, [:exporter, :exporter_opts])
    metadata = %{model_provider: "openai", model_name: model, api: "images"}
    body = request_body(model, prompt, opts)
    client_opts = Keyword.take(opts, [:api_key, :organization, :project, :transport, :transport_opts, :timeout])

    Runner.run(
      "openai:#{model}:images",
      [kind: :generation, inputs: %{prompt: prompt}, tags: [:model, :openai, :image], metadata: metadata],
      exporter_opts,
      fn -> Client.post_json(client_opts, endpoint, body, timeout: Keyword.get(opts, :timeout, 90_000)) end,
      fn run, result -> finish_run(run, result, metadata, exporter_opts) end
    )
  end

  defp request_body(model, prompt, opts) do
    Enum.reduce(@request_fields, %{"model" => model, "prompt" => prompt}, fn field, body ->
      case Keyword.get(opts, field) do
        nil -> body
        value -> Map.put(body, Atom.to_string(field), value)
      end
    end)
  end

  defp finish_run(run, {:ok, response} = result, metadata, exporter_opts) do
    usage = response["usage"] || %{}
    image_count = response |> Map.get("data", []) |> length()

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
