defmodule Mix.Tasks.BeamWeaver.Providers.Matrix do
  @moduledoc """
  Emits the provider compatibility matrix.
  """

  use Mix.Task

  alias BeamWeaver.Provider.Compatibility

  @shortdoc "Prints provider/model capability metadata"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        strict: [check: :boolean, json: :boolean, markdown: :boolean]
      )

    matrix = Compatibility.matrix()

    cond do
      opts[:check] ->
        check!(matrix)

      opts[:markdown] ->
        Mix.shell().info(markdown(matrix))

      true ->
        Mix.shell().info(BeamWeaver.JSON.encode!(matrix))
    end
  end

  defp check!([]), do: Mix.raise("provider compatibility matrix is empty")

  defp check!(matrix) do
    required = [:anthropic, :deepseek, :fake, :google, :openai, :typesafe, :xai, :zai]

    case required -- Enum.map(matrix, & &1.provider) do
      [] -> Mix.shell().info("provider compatibility matrix OK")
      missing -> Mix.raise("provider compatibility matrix is missing: #{inspect(missing)}")
    end
  end

  defp markdown(matrix) do
    features = Compatibility.features()
    header = ["Provider", "Model", "Input", "Output" | Enum.map(features, &to_string/1)]
    divider = Enum.map(header, fn _col -> "---" end)

    rows =
      Enum.map(matrix, fn row ->
        [
          to_string(row.provider),
          row.model,
          inspect(row.max_input_tokens),
          inspect(row.max_output_tokens)
          | Enum.map(features, &flag(row.features[&1]))
        ]
      end)

    Enum.map_join([header, divider | rows], "\n", &("| " <> Enum.join(&1, " | ") <> " |"))
  end

  defp flag(true), do: "yes"
  defp flag(false), do: ""
end
