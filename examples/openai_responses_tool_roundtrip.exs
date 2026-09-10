# Offline: mix run examples/openai_responses_tool_roundtrip.exs
# Live:    mix run examples/openai_responses_tool_roundtrip.exs --live gpt-5.4-mini
# Live mode uses the configured OpenAI API key (OPENAI_API_KEY in runtime.exs).

defmodule BeamWeaver.Examples.ResponsesToolTransport do
  @moduledoc false
  @behaviour BeamWeaver.Transport

  alias BeamWeaver.Transport.Response

  @impl true
  def request(_request, _opts), do: raise("this example requires native streaming")

  @impl true
  def stream_reduce(request, _opts, acc, reducer) do
    true = request.json["stream"]
    input = request.json["input"]

    {text, output, id} =
      if Enum.any?(input, &(&1["type"] == "function_call_output")) do
        # Check the request actually produced by the agent after executing its tool.
        [%{"id" => "fc_multiply", "call_id" => "call_multiply"}] =
          Enum.filter(input, &(&1["type"] == "function_call"))

        [%{"call_id" => "call_multiply", "output" => "391"}] =
          Enum.filter(input, &(&1["type"] == "function_call_output"))

        [%{"id" => "rs_multiply", "encrypted_content" => "fixture-reasoning"}] =
          Enum.filter(input, &(&1["type"] == "reasoning"))

        {"391", [text_item("msg_answer", "391")], "resp_answer"}
      else
        {"Calculating. ",
         [
           %{"type" => "reasoning", "id" => "rs_multiply", "summary" => [], "encrypted_content" => "fixture-reasoning"},
           text_item("msg_calculating", "Calculating. "),
           %{
             "type" => "function_call",
             "id" => "fc_multiply",
             "call_id" => "call_multiply",
             "name" => "multiply",
             "arguments" => ~s({"a":17,"b":23})
           }
         ], "resp_calculating"}
      end

    calls =
      output
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {%{"type" => "function_call"} = call, index} ->
          [
            %{
              "type" => "response.output_item.added",
              "output_index" => index,
              "item" => Map.put(call, "arguments", "")
            },
            %{
              "type" => "response.function_call_arguments.delta",
              "output_index" => index,
              "item_id" => call["id"],
              "delta" => call["arguments"]
            }
          ]

        _ ->
          []
      end)

    response = %{
      "id" => id,
      "model" => request.json["model"],
      "status" => "completed",
      "output" => output,
      "usage" => %{"input_tokens" => 8, "output_tokens" => 4, "total_tokens" => 12}
    }

    {message, index} = output |> Enum.with_index() |> Enum.find(fn {item, _index} -> item["type"] == "message" end)

    events =
      [
        %{
          "type" => "response.output_text.delta",
          "item_id" => message["id"],
          "output_index" => index,
          "content_index" => 0,
          "delta" => text
        }
      ] ++
        calls ++ [%{"type" => "response.completed", "response" => response}]

    # Separate reducer calls exercise incremental parsing, including a terminal
    # response delivered in a different batch from the tool argument deltas.
    acc =
      Enum.reduce(events, acc, fn event, acc ->
        reducer.(acc, "event: #{event["type"]}\ndata: #{BeamWeaver.JSON.encode!(event)}\n\n")
      end)

    {:ok, Response.new(status: 200, headers: [{"content-type", "text/event-stream"}], body: ""), acc}
  end

  defp text_item(id, text) do
    %{
      "type" => "message",
      "id" => id,
      "role" => "assistant",
      "status" => "completed",
      "content" => [%{"type" => "output_text", "text" => text}]
    }
  end
end

alias BeamWeaver.Agent
alias BeamWeaver.Core.Message
alias BeamWeaver.Core.Tool
alias BeamWeaver.OpenAI.ChatModel
alias BeamWeaver.Stream.Envelope
alias BeamWeaver.Stream.Events

model =
  case System.argv() do
    [] ->
      %ChatModel{
        model: "gpt-5.4-mini",
        api_key: "offline-fixture",
        transport: BeamWeaver.Examples.ResponsesToolTransport
      }

    ["--live", model] ->
      key = BeamWeaver.Config.get([:openai, :api_key])
      if key in [nil, ""], do: raise("configure OPENAI_API_KEY before running live mode")
      %ChatModel{model: model, api_key: key, timeout: 120_000}

    _ ->
      raise "usage: mix run examples/openai_responses_tool_roundtrip.exs [--live MODEL]"
  end

tool =
  Tool.from_function!(
    name: "multiply",
    description: "Multiply two integers using the local calculator.",
    input_schema: %{
      "type" => "object",
      "properties" => %{"a" => %{"type" => "integer"}, "b" => %{"type" => "integer"}},
      "required" => ["a", "b"],
      "additionalProperties" => false
    },
    handler: fn %{"a" => a, "b" => b}, _opts -> a * b end
  )

{:ok, agent} = Agent.build(model: model, tools: [tool], model_opts: [stream: true])

{:ok, stream} =
  Agent.stream_events(
    agent,
    %{messages: [Message.user("Call multiply exactly once with a=17 and b=23. Then reply with only the result.")]},
    live: true,
    stream_mode: :events
  )

# Tokens are text deltas. Message events are complete snapshots; do not append
# their text to the token display a second time.
events =
  Enum.map(stream, fn %Envelope{event: event} ->
    case event do
      %Events.Token{text: text} -> IO.write(text)
      %Events.Error{error: error} -> raise "#{error.type}: #{error.message}"
      _ -> :ok
    end

    event
  end)

IO.puts("")

messages =
  Enum.flat_map(events, fn
    %Events.Message{message: %Message{role: :assistant} = message} -> [message]
    _ -> []
  end)

finishes = Enum.filter(events, &match?(%Events.ToolFinish{}, &1))

[call] = Enum.flat_map(messages, & &1.tool_calls)
[%Events.ToolFinish{tool_call_id: call_id, output: "391"}] = finishes
true = call_id == call.id
true = String.starts_with?(call.provider_id, "fc_")
true = call.call_id == call.id
true = length(messages) == 2
true = length(Enum.uniq_by(messages, & &1.id)) == 2
true = String.trim(Message.text(List.last(messages))) == "391"

IO.inspect(%{provider_id: call.provider_id, call_id: call.call_id, tool_result: "391"},
  label: "Streaming tool round trip passed"
)
