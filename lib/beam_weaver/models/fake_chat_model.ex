defmodule BeamWeaver.Models.FakeChatModel do
  @moduledoc """
  Deterministic chat model for tests and examples.
  """

  @behaviour BeamWeaver.Core.ChatModel

  alias BeamWeaver.Core.LanguageModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Models.InvocationMetadata
  alias BeamWeaver.Models.ParamPolicy
  alias BeamWeaver.Stream
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events

  defstruct responses: [],
            response: nil,
            parent: nil,
            profile: nil,
            stream_chunks: nil,
            stream_events: nil,
            usage_metadata: nil,
            tokenizer: nil,
            param_policy: nil,
            tool_calls: [],
            structured_response: nil,
            error: nil

  @impl true
  def invoke(%__MODULE__{} = model, messages, opts) do
    with :ok <-
           ParamPolicy.validate(
             model.profile,
             opts,
             Keyword.get(opts, :param_policy, model.param_policy)
           ) do
      if model.parent, do: send(model.parent, {:fake_chat_model_call, messages, opts})

      if model.error do
        {:error, model.error}
      else
        response =
          model
          |> next_response(opts)
          |> maybe_put_usage(model.usage_metadata)

        {:ok, response}
      end
    end
  end

  @impl true
  def stream(%__MODULE__{} = model, messages, opts) do
    with :ok <-
           ParamPolicy.validate(
             model.profile,
             opts,
             Keyword.get(opts, :param_policy, model.param_policy)
           ) do
      if model.parent, do: send(model.parent, {:fake_chat_model_stream, messages, opts})

      if is_nil(model.stream_chunks) do
        with {:ok, message} <- invoke(model, messages, opts), do: {:ok, [message]}
      else
        {:ok, model.stream_chunks}
      end
    end
  end

  @impl true
  def stream_events(%__MODULE__{} = model, messages, opts) do
    with :ok <-
           ParamPolicy.validate(
             model.profile,
             opts,
             Keyword.get(opts, :param_policy, model.param_policy)
           ) do
      if model.stream_events do
        {:ok, with_invocation_metadata(model.stream_events, model, opts)}
      else
        with {:ok, message} <- invoke(%{model | parent: nil}, messages, opts) do
          metadata = invocation_metadata(model, opts)

          {:ok,
           [
             Stream.envelope(%Events.Message{message: message}, metadata: metadata),
             Stream.envelope(%Events.Done{usage: message.usage_metadata}, metadata: metadata)
           ]}
        end
      end
    end
  end

  def model_id(_model), do: "chat"
  def profile(%__MODULE__{profile: profile}), do: profile

  def count_tokens(%__MODULE__{tokenizer: nil}, input, _opts),
    do: {:ok, LanguageModel.count_tokens_approximately(input)}

  def count_tokens(%__MODULE__{tokenizer: tokenizer}, input, opts),
    do: LanguageModel.count_tokens({:tokenizer, tokenizer}, input, opts)

  defp next_response(%__MODULE__{structured_response: response} = model, opts)
       when not is_nil(response) do
    if Keyword.has_key?(opts, :response_format) or Keyword.has_key?(opts, :structured_output) do
      Message.assistant(BeamWeaver.JSON.encode!(response),
        metadata: %{parsed: stringify_keys(response)}
      )
    else
      normalize_response(model.response || response_text(model), model.tool_calls)
    end
  end

  defp next_response(%__MODULE__{} = model, _opts) do
    case {model.response, model.responses} do
      {%Message{} = message, _responses} ->
        message

      {response, _responses} when is_binary(response) ->
        normalize_response(response, model.tool_calls)

      {nil, [first | _rest]} ->
        normalize_response(first, model.tool_calls)

      _other ->
        normalize_response("", model.tool_calls)
    end
  end

  defp normalize_response(response, tool_calls)

  defp normalize_response(%Message{} = message, _tool_calls), do: message

  defp normalize_response(text, tool_calls) when is_binary(text),
    do: Message.assistant(text, tool_calls: tool_calls)

  defp response_text(%__MODULE__{structured_response: response}),
    do: BeamWeaver.JSON.encode!(stringify_keys(response))

  defp maybe_put_usage(%Message{} = message, nil), do: message

  defp maybe_put_usage(%Message{} = message, usage) when is_map(usage),
    do: %{message | usage_metadata: usage}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp with_invocation_metadata(events, model, opts) do
    metadata = invocation_metadata(model, opts)

    Enum.map(events, fn
      %Envelope{metadata: event_metadata} = envelope ->
        %{envelope | metadata: Map.merge(metadata, event_metadata || %{})}

      other ->
        other
    end)
  end

  defp invocation_metadata(model, opts) do
    model
    |> InvocationMetadata.fake(opts)
    |> InvocationMetadata.to_metadata_map()
  end
end

defimpl BeamWeaver.Runnable.Configurable, for: BeamWeaver.Models.FakeChatModel do
  def configure(model, values) do
    {:ok,
     struct(
       model,
       Map.take(values, [
         :response,
         :responses,
         :parent,
         :stream_chunks,
         :stream_events,
         :usage_metadata,
         :tokenizer,
         :param_policy,
         :tool_calls,
         :structured_response,
         :error
       ])
     )}
  end
end
