defimpl Inspect, for: [BeamWeaver.DeepSeek.ChatModel, BeamWeaver.DeepSeek.ResponsesModel] do
  def inspect(struct, opts), do: BeamWeaver.Provider.RedactedInspect.redacted_struct(struct, opts)
end
