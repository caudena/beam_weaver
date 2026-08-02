defmodule BeamWeaver.OpenAI.Inspect do
  @moduledoc false

  defdelegate redacted_struct(struct, opts), to: BeamWeaver.Provider.RedactedInspect
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
  def inspect(struct, opts), do: BeamWeaver.Provider.RedactedInspect.redacted_struct(struct, opts)
end
