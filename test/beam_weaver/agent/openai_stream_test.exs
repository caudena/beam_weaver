defmodule BeamWeaver.Agent.OpenAIStreamTest do
  use ExUnit.Case

  # Upstream references:
  # - langgraph/libs/prebuilt/tests/test_tool_call_transformer.py::test_sync_streaming_tool_populates_tool_calls
  # - langgraph/libs/langgraph/tests/test_tool_stream_handler.py::test_started_finished_cycle
  # - langchain/libs/core/tests/unit_tests/output_parsers/test_openai_tools.py streamed tool-call chunks

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.ToolCall
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.OpenAI.ChatModel

  defmodule ContextModel do
    @behaviour BeamWeaver.Core.ChatModel

    defstruct []

    @impl true
    def invoke(%__MODULE__{}, messages, opts) do
      opts
      |> Keyword.fetch!(:context)
      |> Map.fetch!(:model)
      |> BeamWeaver.Core.ChatModel.invoke(messages, opts)
    end

    @impl true
    def stream(%__MODULE__{}, messages, opts) do
      opts
      |> Keyword.fetch!(:context)
      |> Map.fetch!(:model)
      |> BeamWeaver.Core.ChatModel.stream(messages, opts)
    end

    @impl true
    def stream_events(%__MODULE__{}, messages, opts) do
      opts
      |> Keyword.fetch!(:context)
      |> Map.fetch!(:model)
      |> BeamWeaver.Core.ChatModel.stream_events(messages, opts)
    end

    def stream_response(%__MODULE__{}, messages, opts) do
      model =
        opts
        |> Keyword.fetch!(:context)
        |> Map.fetch!(:model)

      if function_exported?(model.__struct__, :stream_response, 3) do
        model.__struct__.stream_response(model, messages, opts)
      else
        BeamWeaver.Core.ChatModel.invoke(model, messages, opts)
      end
    end
  end

  defmodule StreamedOpenAIToolAgent do
    use BeamWeaver.Agent

    context_schema do
      field(:model, :any, required: true)
      field(:parent, :any, required: true)
    end

    model(%ContextModel{}, stream: true)
    tools(__MODULE__.tools())

    def tools do
      [
        Tool.from_function!(
          name: "get_weather",
          description: "Get the current weather",
          input_schema: %{
            "type" => "object",
            "properties" => %{"location" => %{"type" => "string"}},
            "required" => ["location"]
          },
          injected: %{"context" => :context},
          handler: fn %{"location" => location, "context" => context}, _opts ->
            send(context.parent, {:streamed_openai_tool_executed, location})
            "It's sunny."
          end
        )
      ]
    end
  end

  test "generated agent loop executes tool calls reconstructed from streamed OpenAI chunks" do
    prompt = "What is the weather in San Francisco, CA?"

    first_request = %{
      "model" => "gpt-5.4-mini",
      "input" => [%{"type" => "message", "role" => "user", "content" => prompt}],
      "stream" => true,
      "tools" => [openai_weather_tool()]
    }

    first_response = """
    event: response.created
    data: {"type":"response.created","response":{"id":"resp_agent_stream_1","model":"gpt-5.4-mini","output":[]}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_agent_stream","call_id":"call_weather","name":"get_weather","arguments":""}}

    event: response.function_call_arguments.delta
    data: {"type":"response.function_call_arguments.delta","output_index":0,"item_id":"fc_agent_stream","delta":"{\\\"location\\\":"}

    event: response.function_call_arguments.delta
    data: {"type":"response.function_call_arguments.delta","output_index":0,"item_id":"fc_agent_stream","delta":"\\\"San Francisco, CA\\\"}"}

    event: response.function_call_arguments.done
    data: {"type":"response.function_call_arguments.done","output_index":0,"item_id":"fc_agent_stream","name":"get_weather","arguments":"{\\\"location\\\":\\\"San Francisco, CA\\\"}"}

    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"fc_agent_stream","call_id":"call_weather","name":"get_weather","arguments":"{\\\"location\\\":\\\"San Francisco, CA\\\"}","status":"completed"}}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_agent_stream_1","model":"gpt-5.4-mini","output":[]}}

    data: [DONE]
    """

    second_request = %{
      "model" => "gpt-5.4-mini",
      "input" => [
        %{"type" => "message", "role" => "user", "content" => prompt},
        %{
          "type" => "function_call",
          "id" => "fc_agent_stream",
          "call_id" => "call_weather",
          "name" => "get_weather",
          "arguments" => ~s({"location":"San Francisco, CA"})
        },
        %{
          "type" => "function_call_output",
          "call_id" => "call_weather",
          "output" => "It's sunny."
        }
      ],
      "stream" => true,
      "tools" => [openai_weather_tool()]
    }

    second_response = """
    event: response.created
    data: {"type":"response.created","response":{"id":"resp_agent_stream_2","model":"gpt-5.4-mini","output":[]}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_agent_stream","role":"assistant","content":[]}}

    event: response.content_part.added
    data: {"type":"response.content_part.added","output_index":0,"item_id":"msg_agent_stream","content_index":0,"part":{"type":"output_text","text":""}}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","output_index":0,"item_id":"msg_agent_stream","content_index":0,"delta":"It's sunny in San Francisco, CA."}

    event: response.output_text.done
    data: {"type":"response.output_text.done","output_index":0,"item_id":"msg_agent_stream","content_index":0,"text":"It's sunny in San Francisco, CA."}

    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_agent_stream","role":"assistant","status":"completed","content":[{"type":"output_text","text":"It's sunny in San Francisco, CA."}]}}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_agent_stream_2","model":"gpt-5.4-mini","output":[]}}

    data: [DONE]
    """

    model =
      replay_model(
        write_gzip_cassette([
          {first_request, first_response, content_type: "text/event-stream"},
          {second_request, second_response, content_type: "text/event-stream"}
        ])
      )

    assert {:ok, %{messages: messages}} =
             StreamedOpenAIToolAgent.invoke(%{messages: [Message.user(prompt)]},
               context: %{model: model, parent: self()}
             )

    assert_receive {:streamed_openai_tool_executed, "San Francisco, CA"}

    assert Enum.any?(messages, fn
             %Message{role: :assistant, tool_calls: [%ToolCall{call_id: "call_weather"}]} -> true
             _message -> false
           end)

    assert Enum.any?(messages, fn
             %Message{role: :tool, tool_call_id: "call_weather", content: "It's sunny."} -> true
             _message -> false
           end)

    assert %Message{role: :assistant, content: [%{text: "It's sunny in San Francisco, CA."}]} =
             List.last(messages)
  end

  defp replay_model(cassette_path) do
    %ChatModel{
      model: "gpt-5.4-mini",
      api_key: "sk-replay-test",
      transport: BeamWeaver.Transport.Replay,
      transport_opts: [cassette_path: cassette_path]
    }
  end

  defp openai_weather_tool do
    %{
      "type" => "function",
      "name" => "get_weather",
      "description" => "Get the current weather",
      "parameters" => %{
        "type" => "object",
        "properties" => %{"location" => %{"type" => "string"}},
        "required" => ["location"]
      }
    }
  end

  defp write_gzip_cassette(interactions) when is_list(interactions) do
    path =
      Path.join([
        System.tmp_dir!(),
        "beam_weaver_agent_openai_stream_#{System.unique_integer([:positive])}.yaml.gz"
      ])

    File.write!(path, :zlib.gzip(cassette_yaml(interactions)))
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp cassette_yaml(interactions) do
    requests =
      Enum.map_join(interactions, "\n", fn {request_body, _response_body, _opts} ->
        """
        - body: !!binary |
            #{Base.encode64(BeamWeaver.JSON.encode!(request_body))}
          headers:
            authorization:
            - '**REDACTED**'
          method: POST
          uri: https://api.openai.com/v1/responses
        """
      end)

    responses =
      Enum.map_join(interactions, "\n", fn {_request_body, response_body, opts} ->
        content_type = Keyword.get(opts, :content_type, "application/json")

        """
        - body:
            string: !!binary |
              #{Base.encode64(response_body(response_body))}
          headers:
            content-type:
            - #{content_type}
          status:
            code: 200
            message: OK
        """
      end)

    """
    requests:
    #{requests}
    responses:
    #{responses}
    """
  end

  defp response_body(response_body) when is_binary(response_body), do: response_body
  defp response_body(response_body), do: BeamWeaver.JSON.encode!(response_body)
end
