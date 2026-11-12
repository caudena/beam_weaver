defmodule BeamWeaver.Moonshot.ResponsesModelTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.{ChatModel, Message}
  alias BeamWeaver.Models
  alias BeamWeaver.Moonshot.{ResponsesModel, Tools}
  alias BeamWeaver.TestSupport.Conformance.Fakes.Transport

  alias BeamWeaver.Stream.{Envelope, Events}

  defmodule StreamTransport do
    @behaviour BeamWeaver.Transport

    def request(_request, _opts), do: raise("expected streaming")

    def stream_reduce(request, opts, acc, reducer) do
      send(opts[:parent], {:kimi_stream_request, request})
      acc = Enum.reduce(opts[:chunks], acc, fn chunk, acc -> reducer.(acc, chunk) end)
      {:ok, BeamWeaver.Transport.Response.new(status: 200, body: "", headers: opts[:headers] || []), acc}
    end
  end

  test "uses K3.1 Pro by default and registers both published price schedules" do
    assert BeamWeaver.Moonshot.chat_model().model == "kimi-k3.1-pro"

    for {id, input, write_1h, output} <- [
          {"kimi-k3.1-pro", 2.0, 4.0, 10.0},
          {"kimi-k3.1-pro-highspeed", 4.0, 8.0, 20.0}
        ] do
      model = Models.init_chat_model!("moonshot:#{id}")
      assert model.profile.max_input_tokens == 1_048_576
      assert model.profile.extra.input_price_per_mtok == input
      assert model.profile.extra.cached_input_price_per_mtok == 0.20
      assert model.profile.extra.cache_write_1h_price_per_mtok == write_1h
      assert model.profile.extra.output_price_per_mtok == output

      assert {:ok, %{"reasoning_effort" => "low"}} =
               model.__struct__.request_body(model, [Message.user("hello")], reasoning_effort: :low)
    end

    assert Models.init_chat_model!("moonshot:kimi-k2.6").profile.status == :deprecated
  end

  test "sends native hosted search and replays reasoning and tool calls in a stateless follow-up" do
    response = %{
      "id" => "resp_kimi",
      "model" => "kimi-k3.1-pro",
      "status" => "completed",
      "store" => false,
      "output" => [
        %{
          "type" => "reasoning",
          "id" => "rs_kimi",
          "summary" => [%{"type" => "summary_text", "text" => "Check the data."}]
        },
        %{
          "type" => "function_call",
          "id" => "fc_kimi",
          "call_id" => "call_kimi",
          "name" => "lookup",
          "arguments" => "{}"
        }
      ],
      "usage" => %{"input_tokens" => 20, "output_tokens" => 4}
    }

    model =
      Models.init_chat_model!("moonshot:kimi-k3.1-pro",
        api: :responses,
        base_url: "https://gateway.test/v1",
        api_key: "test-key",
        transport: Transport,
        transport_opts: [parent: self(), body: response, headers: [{"msh-usage-cache-write-tokens-1h", "12"}]]
      )

    start = Message.user("Look it up.")
    tool = %{"type" => "function", "name" => "lookup", "parameters" => %{"type" => "object", "properties" => %{}}}

    assert {:ok, reply} =
             ChatModel.invoke(model, [start],
               tools: [tool, Tools.responses_web_search(filters: %{allowed_domains: ["elixir-lang.org"]})],
               include: ["web_search_call.action.sources"],
               reasoning_effort: :low,
               prompt_cache_options: %{mode: :implicit, ttl: "1h"}
             )

    assert_received {:fake_transport_request, request}
    assert request.url == "https://gateway.test/v1/responses"
    assert request.json["reasoning"] == %{"effort" => "low"}
    assert request.json["prompt_cache_options"] == %{"mode" => "implicit", "ttl" => "1h"}
    assert Enum.any?(request.json["tools"], &match?(%{"type" => "web_search"}, &1))
    assert reply.response_metadata.model_provider == "moonshot"
    assert reply.usage_metadata.input_token_details.ephemeral_1h_input_tokens == 12
    assert [%{call_id: "call_kimi"}] = reply.tool_calls

    tool_reply = Message.tool("Found it.", name: "lookup", tool_call_id: "call_kimi")
    assert {:ok, followup} = ResponsesModel.request_body(model, [start, reply, tool_reply], tools: [tool])

    assert Enum.any?(
             followup["input"],
             &match?(%{"type" => "reasoning", "summary" => [%{"text" => "Check the data."}]}, &1)
           )

    assert Enum.any?(followup["input"], &match?(%{"type" => "function_call", "call_id" => "call_kimi"}, &1))

    assert List.last(followup["input"]) == %{
             "type" => "function_call_output",
             "call_id" => "call_kimi",
             "output" => "Found it."
           }

    refute Map.has_key?(followup, "previous_response_id")
    refute Map.has_key?(followup, "store")
  end

  test "typed Responses streaming reports Moonshot and retains the terminal provider message" do
    response = %{
      "id" => "resp_kimi",
      "model" => "kimi-k3.1-pro",
      "status" => "completed",
      "output" => [
        %{"type" => "message", "role" => "assistant", "content" => [%{"type" => "output_text", "text" => "Ready."}]}
      ],
      "usage" => %{"input_tokens" => 10, "output_tokens" => 2, "total_tokens" => 12}
    }

    events = [
      %{"type" => "response.output_text.delta", "item_id" => "msg_kimi", "delta" => "Ready."},
      %{"type" => "response.completed", "response" => response}
    ]

    chunks = Enum.map(events, &"event: #{&1["type"]}\ndata: #{BeamWeaver.JSON.encode!(&1)}\n\n")

    model =
      Models.init_chat_model!("moonshot:kimi-k3.1-pro",
        api: :responses,
        api_key: "fixture",
        transport: StreamTransport,
        transport_opts: [
          parent: self(),
          chunks: chunks,
          headers: [{"msh-request-id", "kimi-stream-id"}, {"msh-usage-cache-write-tokens-1h", "4"}]
        ]
      )

    assert {:ok, stream} = ChatModel.stream_typed_events(model, "Say ready.")
    events = Enum.to_list(stream)
    assert_received {:kimi_stream_request, request}
    assert request.json["stream"] == true

    assert Enum.any?(events, fn
             %Envelope{event: %Events.Token{text: "Ready."}, metadata: %{provider: :moonshot}} -> true
             _ -> false
           end)

    assert Enum.any?(events, fn
             %Envelope{event: %Events.Message{message: reply}} ->
               Message.text(reply) == "Ready." and reply.response_metadata.model_provider == "moonshot" and
                 reply.response_metadata.request_id == "kimi-stream-id" and
                 reply.usage_metadata.input_token_details.ephemeral_1h_input_tokens == 4

             _ ->
               false
           end)
  end

  test "hosted web search validates the allowed filter and rejects a second search tool" do
    model = BeamWeaver.Moonshot.responses_model()
    messages = [Message.user("Search for the Elixir project.")]
    search = Tools.responses_web_search(filters: %{allowed_domains: ["elixir-lang.org"]})

    assert {:ok, %{"tools" => [^search]}} = ResponsesModel.request_body(model, messages, tools: [search])

    for tools <- [[search, search], [Tools.responses_web_search(filters: %{blocked_domains: ["example.org"]})]] do
      assert {:error, %{details: %{params: [:tools]}}} = ResponsesModel.request_body(model, messages, tools: tools)
    end
  end

  test "rejects incompatible models and stateless or tool-choice violations before transport" do
    assert {:error, %{type: :unsupported_model}} =
             Models.init_chat_model("moonshot:kimi-k2.6", api: :responses)

    model = BeamWeaver.Moonshot.responses_model()
    messages = [Message.user("Hello")]

    assert {:error, %{details: %{params: [:use_previous_response_id]}}} =
             ResponsesModel.request_body(model, messages, use_previous_response_id: true)

    assert {:error, %{details: %{params: [:tool_choice]}}} =
             ResponsesModel.request_body(model, messages, tool_choice: :required)
  end
end
