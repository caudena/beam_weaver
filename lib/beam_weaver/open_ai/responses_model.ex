defmodule BeamWeaver.OpenAI.ResponsesModel do
  @moduledoc ~S"""
  OpenAI Responses model implementing the BeamWeaver chat contract.

  Prefer `BeamWeaver.Models.init_chat_model/2` for provider-prefixed identifiers,
  then call `BeamWeaver.Core.ChatModel` or declare the model in an agent.
  Construction does not contact the provider. Model/profile options describe
  local compatibility; account access is established only by a real request.

  See [OpenAI](providers/openai.md) for endpoint-specific parameters, reasoning,
  media and tools. Preserve complete messages for multi-turn replay. Streaming
  consumers must enumerate once and handle terminal errors; display text is not
  a lossless representation of a native provider turn.
  """

  use BeamWeaver.Provider.RedactedInspect

  @behaviour BeamWeaver.Core.ChatModel

  alias BeamWeaver.OpenAI.ChatModel

  defstruct %ChatModel{} |> Map.from_struct() |> Map.to_list()

  @type t :: %__MODULE__{}

  @impl true
  def invoke(%__MODULE__{} = model, messages, opts \\ []),
    do: ChatModel.invoke(to_chat_model(model), messages, opts)

  @impl true
  def stream(%__MODULE__{} = model, messages, opts \\ []),
    do: ChatModel.stream(to_chat_model(model), messages, opts)

  def stream_response(%__MODULE__{} = model, messages, opts \\ []),
    do: ChatModel.stream_response(to_chat_model(model), messages, opts)

  @impl true
  def stream_events(%__MODULE__{} = model, messages, opts \\ []),
    do: ChatModel.stream_events(to_chat_model(model), messages, opts)

  @impl true
  def stream_typed_events(%__MODULE__{} = model, messages, opts \\ []),
    do: ChatModel.stream_typed_events(to_chat_model(model), messages, opts)

  @impl true
  def stream_exact_typed_events(%__MODULE__{} = model, body, opts \\ [])
      when is_binary(body),
      do: ChatModel.stream_exact_typed_events(to_chat_model(model), body, opts)

  def request_body(%__MODULE__{} = model, messages, opts \\ []),
    do: ChatModel.request_body(to_chat_model(model), messages, opts)

  def model_id(%__MODULE__{model: model}), do: model
  def profile(%__MODULE__{profile: profile}), do: profile

  def count_tokens(%__MODULE__{} = model, input, opts),
    do: ChatModel.count_tokens(to_chat_model(model), input, opts)

  defp to_chat_model(%__MODULE__{} = model) do
    struct(ChatModel, Map.from_struct(model))
  end
end
