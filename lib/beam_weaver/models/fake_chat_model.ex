defmodule BeamWeaver.Models.FakeChatModel do
  @moduledoc ~S"""
  A scripted chat model for tests, examples and documentation. It needs no API
  key and always answers the same way.

  Script a conversation with `responses:`, one entry per model turn:

  ```elixir
  alias BeamWeaver.Models.FakeChatModel

  defmodule MyApp.Tools.LookupOrder do
    use BeamWeaver.Tool

    name "lookup_order"
    description "Look up an order by its id."

    schema do
      field :order_id, :string
    end

    @impl true
    def invoke(_tool, %{"order_id" => order_id}, _opts), do: {:ok, "#{order_id} shipped on Monday."}
  end

  defmodule MyApp.SupportAgent do
    use BeamWeaver.Agent

    model "fake:chat",
      responses: [
        FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1001"}),
        "Order A-1001 shipped on Monday."
      ]

    tools [MyApp.Tools.LookupOrder]
  end

  {:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Where is my order A-1001?"]})
  Enum.map(result.messages, & &1.role)
  #=> [:user, :assistant, :tool, :assistant]
  ```

  An entry is a string, a `%BeamWeaver.Core.Message{}`, a `tool_call/2` or
  `tool_calls/1` turn, or a `final/1` structured answer. The turn is read from
  the conversation: every reply is stamped with its turn in
  `metadata.fake_turn`, so the script continues through an agent's tool loop
  and across resumed threads. The last entry repeats once the script runs out.

  Other options:

    * `stream: true`, in an agent's model options, streams the reply word by
      word as `Token` and `MessageChunk` events.
    * `error:` makes every call fail with that error.
    * `parent:` sends `{:fake_chat_model_call, messages, opts}` to that process
      on every call.
    * `usage_metadata:` adds token counts and costs to every reply.

  See [Testing](testing.md).
  """

  @behaviour BeamWeaver.Core.ChatModel

  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.LanguageModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages
  alias BeamWeaver.Core.Messages.ToolCall
  alias BeamWeaver.Models.InvocationMetadata
  alias BeamWeaver.Models.ParamPolicy
  alias BeamWeaver.Stream
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events

  import BeamWeaver.Core.Messages.Serialization, only: [stringify_value: 1]

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
            streaming: false,
            error: nil

  @doc "A scripted turn in which the model calls one tool."
  @spec tool_call(String.t() | atom(), map()) :: {:tool_calls, [{String.t(), map()}]}
  def tool_call(name, args \\ %{}) when is_map(args), do: tool_calls([{name, args}])

  @doc "A scripted turn in which the model calls several tools at once."
  @spec tool_calls([{String.t() | atom(), map()}]) :: {:tool_calls, [{String.t(), map()}]}
  def tool_calls(calls) when is_list(calls),
    do: {:tool_calls, Enum.map(calls, fn {name, args} when is_map(args) -> {to_string(name), args} end)}

  @doc """
  A scripted structured answer.

  It is returned the way the request asks for it: as JSON with the parsed
  value in `metadata.parsed` for a response schema, or as a call to the
  structured-output tool when the agent uses the tool strategy.
  """
  @spec final(map()) :: {:final, map()}
  def final(data) when is_map(data), do: {:final, data}

  @impl true
  def invoke(%__MODULE__{} = model, messages, opts) do
    with :ok <- validate_params(model, opts) do
      if model.parent, do: send(model.parent, {:fake_chat_model_call, messages, opts})

      if model.error do
        {:error, model.error}
      else
        response =
          model
          |> next_response(messages, opts)
          |> maybe_put_usage(model.usage_metadata)

        {:ok, response}
      end
    end
  end

  @impl true
  def stream(%__MODULE__{} = model, messages, opts) do
    with :ok <- validate_params(model, opts) do
      if model.parent, do: send(model.parent, {:fake_chat_model_stream, messages, opts})

      if is_nil(model.stream_chunks) do
        with {:ok, message} <- invoke(model, messages, opts), do: {:ok, [message]}
      else
        {:ok, model.stream_chunks}
      end
    end
  end

  # Agents stream through this callback when `stream: true` is set. Without
  # custom chunks the reply arrives word by word as Token and MessageChunk
  # events, the way provider streams do, followed by the whole message.
  @impl true
  def stream_typed_events(%__MODULE__{stream_chunks: nil, stream_events: nil} = model, messages, opts) do
    with :ok <- validate_params(model, opts) do
      if model.parent, do: send(model.parent, {:fake_chat_model_stream, messages, opts})

      with {:ok, message} <- invoke(%{model | parent: nil}, messages, opts) do
        metadata = invocation_metadata(model, opts)

        chunks =
          message
          |> Message.text()
          |> String.split(~r/(?<=\s)/u, trim: true)
          |> Enum.flat_map(fn text ->
            [
              Stream.envelope(%Events.Token{text: text}, metadata: metadata),
              Stream.envelope(%Events.MessageChunk{chunk: Messages.ai_chunk(text)}, metadata: metadata)
            ]
          end)

        {:ok, chunks ++ reply_events(message, metadata)}
      end
    end
  end

  def stream_typed_events(%__MODULE__{} = model, messages, opts) do
    with {:ok, chunks} <- stream(model, messages, opts),
         do: {:ok, ChatModel.stream_event_envelopes(model, chunks, opts)}
  end

  @impl true
  def stream_events(%__MODULE__{} = model, messages, opts) do
    with :ok <- validate_params(model, opts) do
      if model.stream_events do
        {:ok, with_invocation_metadata(model.stream_events, model, opts)}
      else
        with {:ok, message} <- invoke(%{model | parent: nil}, messages, opts),
             do: {:ok, reply_events(message, invocation_metadata(model, opts))}
      end
    end
  end

  def model_id(_model), do: "chat"
  def profile(%__MODULE__{profile: profile}), do: profile

  def count_tokens(%{tokenizer: nil}, input, _opts), do: {:ok, LanguageModel.count_tokens_approximately(input)}

  def count_tokens(%{tokenizer: tokenizer}, input, opts),
    do: LanguageModel.count_tokens({:tokenizer, tokenizer}, input, opts)

  defp validate_params(model, opts),
    do: ParamPolicy.validate(model.profile, opts, Keyword.get(opts, :param_policy, model.param_policy))

  defp next_response(%__MODULE__{response: nil, responses: [_ | _] = script} = model, messages, opts) do
    turn = turn(messages)

    script
    |> Enum.at(min(turn, length(script) - 1))
    |> render_turn(turn, model, opts)
    |> then(&%{&1 | metadata: Map.put(&1.metadata || %{}, :fake_turn, turn)})
  end

  defp next_response(%__MODULE__{structured_response: response} = model, _messages, opts)
       when not is_nil(response) do
    if Keyword.has_key?(opts, :response_format) or Keyword.has_key?(opts, :structured_output) do
      Message.assistant(BeamWeaver.JSON.encode!(response),
        metadata: %{parsed: stringify_value(response)}
      )
    else
      normalize_response(model.response || BeamWeaver.JSON.encode!(stringify_value(response)), model.tool_calls)
    end
  end

  defp next_response(%__MODULE__{} = model, _messages, _opts) do
    case model.response do
      %Message{} = message -> message
      response when is_binary(response) -> normalize_response(response, model.tool_calls)
      _other -> normalize_response("", model.tool_calls)
    end
  end

  # The next turn follows the latest stamped reply; a conversation without
  # stamps (seeded or summarized history) counts its assistant messages.
  defp turn(messages) do
    stamped = for %Message{role: :assistant, metadata: metadata} <- messages, turn = fake_turn(metadata), do: turn

    case stamped do
      [] -> Enum.count(messages, &match?(%Message{role: :assistant}, &1))
      turns -> Enum.max(turns) + 1
    end
  end

  defp fake_turn(%{fake_turn: turn}) when is_integer(turn), do: turn
  defp fake_turn(%{"fake_turn" => turn}) when is_integer(turn), do: turn
  defp fake_turn(_metadata), do: nil

  defp render_turn(%Message{} = message, _turn, _model, _opts), do: message
  defp render_turn(text, _turn, model, _opts) when is_binary(text), do: normalize_response(text, model.tool_calls)

  defp render_turn({:tool_calls, calls}, turn, _model, _opts) do
    tool_calls =
      calls
      |> Enum.with_index()
      |> Enum.map(fn {{name, args}, index} ->
        %ToolCall{id: "call_#{turn}_#{index}", name: name, args: stringify_value(args)}
      end)

    Message.assistant("", tool_calls: tool_calls)
  end

  defp render_turn({:final, data}, turn, model, opts) do
    case Keyword.get(opts, :structured_output_tool_names) do
      [name | _rest] -> render_turn({:tool_calls, [{name, data}]}, turn, model, opts)
      _other -> Message.assistant(BeamWeaver.JSON.encode!(data), metadata: %{parsed: stringify_value(data)})
    end
  end

  defp normalize_response(%Message{} = message, _tool_calls), do: message

  defp normalize_response(text, tool_calls) when is_binary(text),
    do: Message.assistant(text, tool_calls: tool_calls)

  defp maybe_put_usage(%Message{} = message, nil), do: message

  defp maybe_put_usage(%Message{} = message, usage) when is_map(usage),
    do: %{message | usage_metadata: usage}

  defp reply_events(message, metadata) do
    [
      Stream.envelope(%Events.Message{message: message}, metadata: metadata),
      Stream.envelope(%Events.Done{usage: message.usage_metadata}, metadata: metadata)
    ]
  end

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
