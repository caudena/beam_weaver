defmodule BeamWeaver.OpenAI.Inspect do
  @moduledoc false

  import Inspect.Algebra

  alias BeamWeaver.Transport.Redactor

  def redacted_struct(%module{} = struct, opts) do
    fields =
      struct
      |> Map.from_struct()
      |> Redactor.redact()

    concat(["#", module_name(module), "<", to_doc(fields, opts), ">"])
  end

  defp module_name(module) do
    module
    |> Atom.to_string()
    |> String.trim_leading("Elixir.")
  end
end

defimpl Inspect,
  for: [
    BeamWeaver.OpenAI.ChatModel,
    BeamWeaver.OpenAI.ChatCompletionsModel,
    BeamWeaver.OpenAI.Client,
    BeamWeaver.OpenAI.EmbeddingModel,
    BeamWeaver.OpenAI.ModerationMiddleware,
    BeamWeaver.OpenAI.ResponsesModel
  ] do
  def inspect(struct, opts), do: BeamWeaver.OpenAI.Inspect.redacted_struct(struct, opts)
end
