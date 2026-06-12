defmodule BeamWeaver.OpenAI.ResponsesModel do
  @moduledoc """
  Explicit OpenAI Responses API chat model.

  `BeamWeaver.OpenAI.ChatModel` remains source-compatible and uses the same
  implementation. This module gives applications a clear API-specific model
  struct without changing the existing default.
  """

  @behaviour BeamWeaver.Core.ChatModel

  alias BeamWeaver.OpenAI.ChatModel
  alias BeamWeaver.Provider.ChatModel.Options, as: ChatOptions

  defstruct %ChatModel{} |> Map.from_struct() |> Map.to_list()

  @type t :: %__MODULE__{}

  @impl true
  def invoke(%__MODULE__{} = model, messages, opts \\ []),
    do: ChatModel.invoke(to_chat_model(model), messages, opts)

  @impl true
  def stream(%__MODULE__{} = model, messages, opts \\ []),
    do: ChatModel.stream(to_chat_model(model), messages, opts)

  def async_invoke(%__MODULE__{} = model, messages, opts \\ []),
    do: ChatModel.async_invoke(to_chat_model(model), messages, opts)

  def async_batch(%__MODULE__{} = model, message_batches, opts \\ []),
    do: ChatModel.async_batch(to_chat_model(model), message_batches, opts)

  def async_stream(%__MODULE__{} = model, messages, opts \\ []),
    do: ChatModel.async_stream(to_chat_model(model), messages, opts)

  def stream_response(%__MODULE__{} = model, messages, opts \\ []),
    do: ChatModel.stream_response(to_chat_model(model), messages, opts)

  def async_stream_response(%__MODULE__{} = model, messages, opts \\ []),
    do: ChatModel.async_stream_response(to_chat_model(model), messages, opts)

  @impl true
  def stream_events(%__MODULE__{} = model, messages, opts \\ []),
    do: ChatModel.stream_events(to_chat_model(model), messages, opts)

  def async_stream_events(%__MODULE__{} = model, messages, opts \\ []),
    do: ChatModel.async_stream_events(to_chat_model(model), messages, opts)

  def request_body(%__MODULE__{} = model, messages, opts \\ []),
    do: ChatModel.request_body(to_chat_model(model), messages, opts)

  def model_id(%__MODULE__{} = model), do: ChatOptions.model_id(model)
  def profile(%__MODULE__{} = model), do: ChatOptions.profile(model)

  def count_tokens(%__MODULE__{} = model, input, opts),
    do: ChatModel.count_tokens(to_chat_model(model), input, opts)

  defp to_chat_model(%__MODULE__{} = model) do
    struct(ChatModel, Map.from_struct(model))
  end
end
