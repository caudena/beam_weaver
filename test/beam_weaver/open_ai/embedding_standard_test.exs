defmodule BeamWeaver.OpenAI.EmbeddingStandardTest do
  use BeamWeaver.TestSupport.Conformance.EmbeddingModelCase,
    model:
      {BeamWeaver.OpenAI.EmbeddingModel,
       [
         api_key: "sk-replay-test",
         transport: BeamWeaver.Transport.Replay,
         transport_opts: [cassette_path: "priv/openai/cassettes/standard_embeddings.yaml"]
       ]}
end
