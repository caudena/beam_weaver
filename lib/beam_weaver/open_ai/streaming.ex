defmodule BeamWeaver.OpenAI.Streaming do
  @moduledoc """
  Parser for OpenAI server-sent event response bodies.
  """

  alias BeamWeaver.OpenAI.Streaming.Lifecycle
  alias BeamWeaver.OpenAI.Streaming.Messages, as: StreamingMessages
  alias BeamWeaver.OpenAI.Streaming.Response
  alias BeamWeaver.OpenAI.Streaming.SSE

  @doc """
  Reconstructs a Responses API JSON response from an SSE payload.
  """
  @spec response(binary() | term()) :: map()
  def response(body), do: Response.response(body)

  @doc """
  Converts OpenAI SSE payloads into content-block lifecycle events.
  """
  @spec lifecycle_events(binary() | [map()] | term()) :: [map()]
  def lifecycle_events(body) when is_binary(body) do
    Lifecycle.events(body)
  end

  def lifecycle_events(parsed_events) when is_list(parsed_events),
    do: Lifecycle.events(parsed_events)

  def lifecycle_events(_body), do: []

  @doc """
  Converts OpenAI SSE payloads into typed BeamWeaver message chunks.
  """
  @spec message_chunks(binary() | [map()] | term()) :: [term()]
  def message_chunks(body) when is_binary(body) do
    StreamingMessages.message_chunks(body)
  end

  def message_chunks(parsed_events) when is_list(parsed_events),
    do: StreamingMessages.message_chunks(parsed_events)

  def message_chunks(_body), do: []

  @doc """
  Converts OpenAI SSE payloads into BeamWeaver typed stream envelopes.
  """
  @spec typed_events(binary() | [map()] | term()) :: [BeamWeaver.Stream.Envelope.t()]
  def typed_events(body) when is_binary(body) do
    StreamingMessages.typed_events(body)
  end

  def typed_events(parsed_events) when is_list(parsed_events),
    do: StreamingMessages.typed_events(parsed_events)

  def typed_events(_body), do: []

  @doc """
  Reconstructs Responses API output items from an SSE payload.
  """
  @spec output_items(binary() | [map()] | term()) :: [map()]
  def output_items(body), do: Response.output_items(body)

  @doc """
  Extracts streamed partial image payloads from image generation SSE events.
  """
  @spec partial_images(binary() | term()) :: [map()]
  def partial_images(body), do: Response.partial_images(body)

  @doc """
  Extracts text deltas from Responses API or chat-completions SSE payloads.
  """
  @spec text_deltas(binary() | term()) :: [String.t()]
  def text_deltas(body) when is_binary(body) do
    body
    |> events()
    |> Enum.flat_map(&text_delta/1)
  end

  def text_deltas(parsed_events) when is_list(parsed_events) do
    Enum.flat_map(parsed_events, &text_delta/1)
  end

  def text_deltas(_body), do: []

  @doc """
  Extracts reasoning summary deltas from Responses API SSE payloads.
  """
  @spec reasoning_summary_deltas(binary() | term()) :: [String.t()]
  def reasoning_summary_deltas(body) when is_binary(body) do
    body
    |> events()
    |> reasoning_summary_deltas()
  end

  def reasoning_summary_deltas(parsed_events) when is_list(parsed_events) do
    Enum.flat_map(parsed_events, fn
      %{"data" => %{"type" => "response.reasoning_summary_text.delta", "delta" => delta}}
      when is_binary(delta) ->
        [delta]

      _event ->
        []
    end)
  end

  def reasoning_summary_deltas(_body), do: []

  @doc """
  Parses server-sent events into decoded event/data maps.
  """
  @spec events(binary() | term()) :: [map()]
  def events(body) when is_binary(body) do
    SSE.events(body)
  end

  def events(_body), do: []

  defp text_delta(%{"data" => %{"type" => "response.output_text.delta", "delta" => delta}})
       when is_binary(delta),
       do: [delta]

  defp text_delta(%{"data" => %{"choices" => choices}}) when is_list(choices) do
    choices
    |> Enum.flat_map(fn choice ->
      cond do
        is_binary(get_in(choice, ["delta", "content"])) ->
          [get_in(choice, ["delta", "content"])]

        is_binary(choice["text"]) ->
          [choice["text"]]

        true ->
          []
      end
    end)
  end

  defp text_delta(_event), do: []
end
