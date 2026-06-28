defmodule BeamWeaver.OpenAI.ResponsesTest do
  use ExUnit.Case

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Models
  alias BeamWeaver.OpenAI
  alias BeamWeaver.OpenAI.ChatModel
  alias BeamWeaver.OpenAI.Client
  alias BeamWeaver.OpenAI.Responses
  alias BeamWeaver.OpenAI.ResponsesModel

  test "builds raw Responses API input items" do
    assert Responses.message(:user, "hello", id: "msg_1") == %{
             "type" => "message",
             "role" => "user",
             "content" => "hello",
             "id" => "msg_1"
           }

    assert Responses.function_call_output(%{"call_id" => "call_1"}, %{ok: true}) == %{
             "type" => "function_call_output",
             "call_id" => "call_1",
             "output" => ~s({"ok":true})
           }

    assert Responses.custom_tool_call_output("call_custom", "27") == %{
             "type" => "custom_tool_call_output",
             "call_id" => "call_custom",
             "output" => "27"
           }

    assert Responses.mcp_approval_response(%{"id" => "mcpr_1"}, false) == %{
             "type" => "mcp_approval_response",
             "approval_request_id" => "mcpr_1",
             "approve" => false
           }
  end

  test "builds computer-call output items from image content" do
    image = %{"type" => "input_image", "image_url" => "data:image/png;base64,<image_data>"}

    assert Responses.computer_call_output("call_abc123", [image]) == %{
             "type" => "computer_call_output",
             "call_id" => "call_abc123",
             "output" => image
           }

    assert Responses.computer_call_output(
             %{"call_id" => "call_abc123"},
             "data:image/png;base64,<image_data>",
             acknowledged_safety_checks: [
               %{
                 id: "cu_sc_abc234",
                 code: "malicious_instructions",
                 message: "Malicious instructions detected."
               }
             ]
           ) == %{
             "type" => "computer_call_output",
             "call_id" => "call_abc123",
             "output" => image,
             "acknowledged_safety_checks" => [
               %{
                 "id" => "cu_sc_abc234",
                 "code" => "malicious_instructions",
                 "message" => "Malicious instructions detected."
               }
             ]
           }
  end

  test "returns preserved raw output items from assistant messages" do
    message =
      Message.assistant("",
        metadata: %{
          output: [
            %{"type" => "reasoning", "id" => "rs_1"},
            %{"type" => "custom_tool_call", "call_id" => "call_1"}
          ]
        }
      )

    assert [%{"type" => "reasoning"}, %{"type" => "custom_tool_call"}] =
             Responses.output_items(message)

    assert %{"call_id" => "call_1"} =
             Responses.first_output_item(message, "custom_tool_call")
  end

  test "explicit Responses model preserves ChatModel behavior and request options" do
    # Upstream reference:
    assert %ResponsesModel{} = explicit = OpenAI.responses_model(model: "gpt-5.4-mini")
    assert %ChatModel{} = OpenAI.chat_model(model: "gpt-5.4-mini")

    assert {:ok, model} = Models.init_chat_model("openai:gpt-5.4-mini")

    assert {:ok, body} =
             ResponsesModel.request_body(
               struct(explicit, profile: model.profile),
               [Message.user("continue")],
               background: true,
               conversation: %{id: "conv_123"},
               include: ["reasoning.encrypted_content"],
               instructions: "Be brief",
               context_management: [%{type: "summarize", keep: "recent"}],
               max_tool_calls: 2,
               previous_response_id: "resp_prev",
               prompt: %{id: "prompt_123", variables: %{name: "Nate"}},
               prompt_cache_key: "cache-key",
               prompt_cache_retention: :in_memory,
               safety_identifier: "safe-user",
               stream_options: %{include_usage: true},
               tool_choice: %{type: "function", name: "lookup"},
               top_logprobs: 2,
               truncation: "auto",
               extra_body: %{vendor_flag: true}
             )

    assert body["model"] == "gpt-5.4-mini"
    assert body["background"] == true
    assert body["conversation"] == %{"id" => "conv_123"}
    assert body["include"] == ["reasoning.encrypted_content"]
    assert body["instructions"] == "Be brief"
    assert body["context_management"] == [%{"type" => "summarize", "keep" => "recent"}]
    assert body["max_tool_calls"] == 2
    assert body["previous_response_id"] == "resp_prev"
    assert body["prompt"] == %{"id" => "prompt_123", "variables" => %{"name" => "Nate"}}
    assert body["prompt_cache_key"] == "cache-key"
    assert body["prompt_cache_retention"] == "in_memory"
    assert body["safety_identifier"] == "safe-user"
    assert body["stream_options"] == %{"include_usage" => true}
    assert body["tool_choice"] == %{"type" => "function", "name" => "lookup"}
    assert body["top_logprobs"] == 2
    assert body["truncation"] == "auto"
    assert body["vendor_flag"] == true
  end

  test "Responses prompt_cache_key follows first-class, model kwargs, and per-call precedence" do
    # Upstream reference:
    model = %BeamWeaver.OpenAI.ChatModel{
      model: "gpt-5.4-mini",
      prompt_cache_key: "first-class-cache",
      model_kwargs: %{prompt_cache_key: "model-level-cache"}
    }

    assert {:ok, from_model_kwargs} =
             BeamWeaver.OpenAI.ChatModel.request_body(model, [Message.user("Hello")])

    assert from_model_kwargs["prompt_cache_key"] == "first-class-cache"

    assert {:ok, per_call} =
             BeamWeaver.OpenAI.ChatModel.request_body(model, [Message.user("Hello")],
               prompt_cache_key: "per-call-cache"
             )

    assert per_call["prompt_cache_key"] == "per-call-cache"
  end

  test "Responses request body can continue after previous response id" do
    model = %ChatModel{model: "gpt-5.4-mini"}

    messages = [
      Message.user("Hello"),
      Message.assistant("Hi", response_metadata: %{id: "resp_123"}),
      Message.user("How are you?"),
      Message.assistant("No response id"),
      Message.user("Continue")
    ]

    assert {:ok, body} =
             ChatModel.request_body(model, messages, use_previous_response_id: true)

    assert body["previous_response_id"] == "resp_123"

    assert [
             %{"role" => "user", "content" => "How are you?"},
             %{"role" => "assistant", "content" => [%{"text" => "No response id"}]},
             %{"role" => "user", "content" => "Continue"}
           ] = body["input"]

    assert {:ok, all_messages} =
             ChatModel.request_body(model, [Message.user("Hello")], use_previous_response_id: true)

    refute Map.has_key?(all_messages, "previous_response_id")
    assert [%{"role" => "user", "content" => "Hello"}] = all_messages["input"]
  end

  test "Responses lifecycle helpers use GET/POST endpoints and decode provider payloads" do
    interactions = [
      %{
        method: "GET",
        uri: "https://api.openai.com/v1/responses/resp_123",
        response: %{"id" => "resp_123", "status" => "completed"}
      },
      %{
        method: "GET",
        uri: "https://api.openai.com/v1/responses/resp_123/input_items",
        response: %{"object" => "list", "data" => [%{"id" => "msg_1"}]}
      },
      %{
        method: "POST",
        uri: "https://api.openai.com/v1/responses/resp_123/compact",
        request: %{"strategy" => "auto"},
        response: %{"id" => "resp_compact", "status" => "completed"}
      }
    ]

    client =
      Client.new(
        api_key: "sk-replay-test",
        transport: BeamWeaver.Transport.Replay,
        transport_opts: [cassette_path: write_gzip_cassette(interactions)]
      )

    assert {:ok, %{"id" => "resp_123", "status" => "completed"}} =
             Client.retrieve_response(client, "resp_123")

    assert {:ok, %{"data" => [%{"id" => "msg_1"}]}} =
             Client.list_response_input_items(client, "resp_123")

    assert {:ok, %{"id" => "resp_compact"}} =
             Client.compact_response(client, "resp_123", %{"strategy" => "auto"})
  end

  defp write_gzip_cassette(interactions) when is_list(interactions) do
    path =
      Path.join([
        System.tmp_dir!(),
        "beam_weaver_openai_responses_#{System.unique_integer([:positive])}.yaml.gz"
      ])

    File.write!(path, :zlib.gzip(cassette_yaml(interactions)))
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp cassette_yaml(interactions) do
    requests =
      Enum.map_join(interactions, "\n", fn interaction ->
        request_body = Map.get(interaction, :request)
        cassette_request_yaml(interaction, request_body)
      end)

    responses =
      Enum.map_join(interactions, "\n", fn interaction ->
        """
        - body:
            string: !!binary |
              #{Base.encode64(BeamWeaver.JSON.encode!(interaction.response))}
          headers:
            content-type:
            - application/json
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

  defp cassette_request_yaml(interaction, nil) do
    """
    - headers:
        authorization:
        - '**REDACTED**'
      method: #{interaction.method}
      uri: #{interaction.uri}
    """
  end

  defp cassette_request_yaml(interaction, request_body) do
    """
    - body: !!binary |
        #{Base.encode64(BeamWeaver.JSON.encode!(request_body))}
      headers:
        authorization:
        - '**REDACTED**'
      method: #{interaction.method}
      uri: #{interaction.uri}
    """
  end
end
