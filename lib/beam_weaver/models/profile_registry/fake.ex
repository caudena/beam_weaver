defmodule BeamWeaver.Models.ProfileRegistry.Fake do
  @moduledoc false

  alias BeamWeaver.Models.Profile
  alias BeamWeaver.Models.ProfileRegistry.Params

  @profiles %{
    {:fake, "chat"} =>
      Profile.new(%{
        provider: :fake,
        id: "chat",
        name: "Fake chat model",
        responses_api: true,
        chat_completions_api: true,
        tool_calling: true,
        tool_choice: true,
        parallel_tool_calls: true,
        structured_output: true,
        streaming: true,
        usage_metadata: true,
        supported_params: Params.responses(),
        supported_params_by_api: %{
          responses: Params.responses(),
          chat_completions: Params.chat_completions()
        },
        tokenizer: :static
      }),
    {:fake, "embedding"} =>
      Profile.new(%{
        provider: :fake,
        id: "embedding",
        name: "Fake embedding model",
        supported_params: Params.embedding(),
        tokenizer: :static
      })
  }

  def profiles_map, do: @profiles
  def profiles, do: Map.values(@profiles)

  def resolve(model) do
    case Map.fetch(@profiles, {:fake, model}) do
      {:ok, profile} -> {:ok, profile}
      :error -> {:fallback, :fake, model}
    end
  end
end
