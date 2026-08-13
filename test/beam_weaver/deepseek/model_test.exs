defmodule BeamWeaver.DeepSeek.ModelTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.DeepSeek.ChatModel
  alias BeamWeaver.DeepSeek.Messages
  alias BeamWeaver.DeepSeek.ResponsesModel
  alias BeamWeaver.DeepSeek.Tools

  defmodule StaticTransport do
    @behaviour BeamWeaver.Transport

    alias BeamWeaver.Transport.Request
    alias BeamWeaver.Transport.Response

    @impl true
    def request(%Request{} = request, opts) do
      if parent = Keyword.get(opts, :parent), do: send(parent, {:request, request})

      {:ok,
       %Response{
         status: Keyword.get(opts, :status, 200),
         headers: Keyword.get(opts, :response_headers, []),
         body: Keyword.fetch!(opts, :response_body),
         metadata: %{}
       }}
    end

    @impl true
    def stream_reduce(%Request{} = request, opts, acc, reducer) do
      with {:ok, response} <- request(request, opts) do
        acc = reducer.(acc, response.body)
        {:ok, %{response | body: ""}, acc}
      end
    end
  end

  @function_tool %{
    "type" => "function",
    "name" => "lookup",
    "description" => "Look something up",
    "parameters" => %{"type" => "object", "properties" => %{}}
  }

  @chat_function_tool %{
    "type" => "function",
    "function" => Map.delete(@function_tool, "type")
  }

  test "Chat defaults to V4 Flash and preserves reasoning replay and prefix completion" do
    model = ChatModel.new()

    assistant =
      Message.assistant("partial",
        metadata: %{reasoning_content: "private chain", prefix: true}
      )

    assert {:ok, body} =
             ChatModel.request_body(model, [Message.user("question"), assistant], thinking: %{type: "disabled"})

    assert body["model"] == "deepseek-v4-flash"

    assert List.last(body["messages"]) == %{
             "role" => "assistant",
             "content" => "partial",
             "reasoning_content" => "private chain",
             "prefix" => true
           }
  end

  test "Chat validates documented numeric request bounds before transport" do
    model = ChatModel.new()
    messages = [Message.user("hello")]

    for {param, value} <- [
          {:max_tokens, 0},
          {:max_tokens, 393_217},
          {:max_tokens, 1.5},
          {:temperature, -0.1},
          {:temperature, 2.1},
          {:top_p, -0.1},
          {:top_p, 1.1}
        ] do
      assert {:error, error} = ChatModel.request_body(model, messages, [{param, value}])
      assert error.type == :invalid_request
      assert error.details.param == param
    end

    assert {:ok, _body} =
             ChatModel.request_body(model, messages,
               max_tokens: 393_216,
               temperature: 2,
               top_p: 1
             )
  end

  test "Chat requires conversation history and validates logprobs as a boolean" do
    model = ChatModel.new()

    assert {:error, error} = ChatModel.request_body(model, [])
    assert error.type == :invalid_messages

    assert {:error, error} =
             ChatModel.request_body(model, [Message.user("hello")], logprobs: "true")

    assert error.type == :invalid_request
    assert error.details.param == :logprobs

    assert {:ok, body} =
             ChatModel.request_body(model, [Message.user("hello")],
               logprobs: true,
               top_logprobs: 20
             )

    assert body["logprobs"] == true
    assert body["top_logprobs"] == 20
  end

  test "Chat requires map stream_options and streaming mode" do
    model = ChatModel.new()
    messages = [Message.user("hello")]

    assert {:error, error} =
             ChatModel.request_body(model, messages, stream: true, stream_options: :usage)

    assert error.type == :invalid_request
    assert error.details.param == :stream_options

    assert {:error, error} =
             ChatModel.request_body(model, messages, stream_options: %{include_usage: true})

    assert error.type == :unsupported_model_param

    assert {:ok, body} =
             ChatModel.request_body(model, messages,
               stream: true,
               stream_options: %{include_usage: true}
             )

    assert body["stream_options"] == %{"include_usage" => true}
  end

  test "Chat explicit tool choice requires thinking explicitly disabled" do
    model = ChatModel.new()
    messages = [Message.user("hello")]

    opts = [
      tools: [@chat_function_tool],
      tool_choice: %{type: "function", function: %{name: "lookup"}}
    ]

    assert {:error, error} = ChatModel.request_body(model, messages, opts)
    assert error.type == :unsupported_model_param
    assert error.details.required == %{thinking: %{type: "disabled"}}

    assert {:ok, body} =
             ChatModel.request_body(
               model,
               messages,
               Keyword.put(opts, :thinking, %{type: "disabled"})
             )

    assert body["tool_choice"] == %{
             "type" => "function",
             "function" => %{"name" => "lookup"}
           }

    for choice <- [:none, :auto, :required] do
      assert {:error, error} =
               ChatModel.request_body(model, messages,
                 tools: [@chat_function_tool],
                 tool_choice: choice
               )

      assert error.type == :unsupported_model_param
      assert error.details.required == %{thinking: %{type: "disabled"}}

      assert {:ok, body} =
               ChatModel.request_body(model, messages,
                 tools: [@chat_function_tool],
                 tool_choice: choice,
                 thinking: %{type: "disabled"}
               )

      assert body["tool_choice"] == Atom.to_string(choice)
    end
  end

  test "Chat rejects non-map model_kwargs from model and invocation options" do
    messages = [Message.user("hello")]

    for {model, opts} <- [
          {ChatModel.new(model_kwargs: [:not, :a, :map]), []},
          {ChatModel.new(), [model_kwargs: "not-a-map"]}
        ] do
      assert {:error, error} = ChatModel.request_body(model, messages, opts)
      assert error.type == :invalid_request
      assert error.details.param == :model_kwargs
    end
  end

  test "Chat validates tools, response format, and tool choice from the final model_kwargs body" do
    messages = [Message.user("hello")]

    assert {:error, error} =
             ChatModel.request_body(ChatModel.new(model_kwargs: %{tools: "not-a-list"}), messages)

    assert error.type == :invalid_request
    assert error.details.param == :tools

    strict = put_in(@chat_function_tool, ["function", "strict"], true)
    loose = put_in(@chat_function_tool, ["function", "name"], "other")

    assert {:error, error} =
             ChatModel.request_body(
               ChatModel.new(model_kwargs: %{tools: [strict, loose]}),
               messages
             )

    assert error.type == :invalid_request
    assert error.details.feature == :strict_tools

    assert {:error, error} =
             ChatModel.request_body(
               ChatModel.new(model_kwargs: %{response_format: %{type: :json_schema}}),
               messages
             )

    assert error.type == :invalid_response_format

    assert {:error, error} =
             ChatModel.request_body(
               ChatModel.new(
                 model_kwargs: %{
                   thinking: %{type: :disabled},
                   tools: [@chat_function_tool],
                   tool_choice: %{type: :function, function: %{name: "missing"}}
                 }
               ),
               messages
             )

    assert error.type == :invalid_request
    assert error.details.name == "missing"

    assert {:ok, body} =
             ChatModel.request_body(
               ChatModel.new(
                 model_kwargs: %{
                   thinking: %{type: :disabled},
                   tools: [@chat_function_tool],
                   tool_choice: %{type: :function, function: %{name: "lookup"}},
                   response_format: %{type: :json_object}
                 }
               ),
               messages
             )

    assert body["response_format"] == %{"type" => "json_object"}
    assert body["tool_choice"] == %{"type" => "function", "function" => %{"name" => "lookup"}}
  end

  test "Chat maps JSON Schema requests to documented JSON object mode with a schema instruction" do
    schema = %{
      "type" => "object",
      "properties" => %{"ok" => %{"type" => "boolean"}}
    }

    assert {:ok, body} =
             ChatModel.request_body(ChatModel.new(), [Message.user("hello")],
               response_format: %{type: :json_schema, name: "answer", schema: schema}
             )

    assert body["response_format"] == %{"type" => "json_object"}
    assert [%{"role" => "system", "content" => instruction}, _user] = body["messages"]
    assert instruction =~ "Schema name: answer"
    assert instruction =~ "Return exactly one JSON object"
  end

  test "Chat model-level response_format and structured_output parse and validate responses" do
    schema = %{
      "type" => "object",
      "properties" => %{"ok" => %{"type" => "boolean"}},
      "required" => ["ok"]
    }

    format = %{
      type: :json_schema,
      name: "answer",
      schema: schema,
      validator: fn
        %{"ok" => true} = parsed -> {:ok, Map.put(parsed, "validated", true)}
        parsed -> {:error, {:unexpected_response, parsed}}
      end
    }

    response_body =
      BeamWeaver.JSON.encode!(%{
        "id" => "chat_structured",
        "model" => "deepseek-v4-flash",
        "choices" => [
          %{
            "finish_reason" => "stop",
            "message" => %{"role" => "assistant", "content" => ~s({"ok":true})}
          }
        ]
      })

    for option <- [:response_format, :structured_output] do
      model =
        ChatModel.new([
          {option, format},
          {:api_key, "test-key"},
          {:transport, StaticTransport},
          {:transport_opts, [response_body: response_body]}
        ])

      assert {:ok, message} = ChatModel.invoke(model, [Message.user("return JSON")])
      assert message.metadata.parsed == %{"ok" => true, "validated" => true}
    end

    rejecting_model =
      ChatModel.new(
        structured_output: %{format | validator: fn _parsed -> {:error, :rejected} end},
        api_key: "test-key",
        transport: StaticTransport,
        transport_opts: [response_body: response_body]
      )

    assert {:error, error} = ChatModel.invoke(rejecting_model, [Message.user("return JSON")])
    assert error.type == :structured_output_parse_error
    assert error.details.reason == ":rejected"
  end

  test "Chat strict mode requires every declared function to be strict" do
    strict = put_in(@chat_function_tool, ["function", "strict"], true)
    loose = put_in(@chat_function_tool, ["function", "name"], "other")

    assert {:error, error} =
             ChatModel.request_body(ChatModel.new(), [Message.user("hello")], tools: [strict, loose])

    assert error.type == :invalid_request
    assert error.details.feature == :strict_tools

    assert {:ok, _body} =
             ChatModel.request_body(ChatModel.new(), [Message.user("hello")],
               tools: [strict, put_in(loose, ["function", "strict"], true)]
             )
  end

  test "non-stream Chat response exposes reasoning as a content block and visible text remains stable" do
    response = %{
      "id" => "chat_1",
      "model" => "deepseek-v4-flash",
      "created" => 1_786_579_200,
      "choices" => [
        %{
          "finish_reason" => "stop",
          "message" => %{"content" => "visible answer", "reasoning_content" => "private chain"}
        }
      ],
      "usage" => %{
        "prompt_tokens" => 10,
        "prompt_cache_hit_tokens" => 4,
        "prompt_cache_miss_tokens" => 6,
        "completion_tokens" => 5,
        "total_tokens" => 15
      }
    }

    assert {:ok, message} = Messages.chat_response_to_message(response)
    assert Message.text(message) == "visible answer"

    assert [%ContentBlock.Reasoning{reasoning: "private chain"}, %ContentBlock.Text{text: "visible answer"}] =
             message.content

    assert message.metadata.reasoning_content == "private chain"
    assert_in_delta message.usage_metadata.total_cost, 0.000004648, 1.0e-12
  end

  test "Responses requires input or instructions and validates request bounds and user" do
    model = ResponsesModel.new()

    assert {:error, error} = ResponsesModel.request_body(model, [])
    assert error.type == :invalid_request
    assert error.message =~ "nonempty input or instructions"

    assert {:ok, body} = ResponsesModel.request_body(model, [], instructions: "Say hello")
    assert body["instructions"] == "Say hello"

    for {param, value} <- [
          {:max_output_tokens, 0},
          {:max_output_tokens, 393_217},
          {:max_output_tokens, 1.5},
          {:temperature, -0.1},
          {:temperature, 2.1},
          {:top_p, -0.1},
          {:top_p, 1.1},
          {:top_logprobs, -1},
          {:top_logprobs, 21},
          {:top_logprobs, 1.5},
          {:user, "spaces are invalid"}
        ] do
      assert {:error, error} =
               ResponsesModel.request_body(model, [Message.user("hello")], [{param, value}])

      assert error.type == :invalid_request
      assert error.details.param == param
    end

    assert {:ok, _body} =
             ResponsesModel.request_body(model, [Message.user("hello")],
               max_output_tokens: 393_216,
               temperature: 2,
               top_p: 1,
               top_logprobs: 20,
               user: "user_123"
             )
  end

  test "Responses validates model overrides and keeps stream authoritative" do
    model = ResponsesModel.new()
    messages = [Message.user("hello")]

    for opts <- [
          [model: "deepseek-v4-pro"],
          [model_kwargs: %{model: "deepseek-v4-pro"}],
          [extra_body: %{model: "deepseek-v4-pro"}]
        ] do
      assert {:ok, body} = ResponsesModel.request_body(model, messages, opts)
      assert body["model"] == "deepseek-v4-pro"
    end

    for opts <- [
          [model: "unknown"],
          [model_kwargs: %{model: "unknown"}],
          [extra_body: %{model: "unknown"}]
        ] do
      assert {:error, error} = ResponsesModel.request_body(model, messages, opts)
      assert error.type == :unsupported_model
      assert error.details.model == "unknown"
    end

    assert {:ok, body} =
             ResponsesModel.request_body(model, messages,
               model_kwargs: %{stream: true},
               extra_body: %{stream: true}
             )

    assert body["model"] == "deepseek-v4-flash"
    assert body["stream"] == false

    assert {:ok, streaming_body} =
             ResponsesModel.request_body(model, messages,
               stream: true,
               model_kwargs: %{stream: false},
               extra_body: %{stream: false}
             )

    assert streaming_body["stream"] == true
  end

  test "Responses rejects malformed option containers as request errors" do
    model = ResponsesModel.new()
    messages = [Message.user("hello")]

    for {param, opts} <- [
          {:tools, [tools: :bad]},
          {:model_kwargs, [model_kwargs: :bad]},
          {:extra_body, [extra_body: :bad]},
          {:reasoning, [reasoning: :high]},
          {:text, [text: :json]},
          {:text, [model_kwargs: %{text: :json}]}
        ] do
      assert {:error, error} = ResponsesModel.request_body(model, messages, opts)
      assert error.type == :invalid_request
      assert error.details.param == param
    end
  end

  test "Responses rejects stateless fields by presence in escape hatches" do
    model = ResponsesModel.new()
    messages = [Message.user("hello")]

    for opts <- [
          [store: false],
          [model_kwargs: %{store: false}],
          [extra_body: %{store: false}],
          [extra_body: %{store: nil}]
        ] do
      assert {:error, error} = ResponsesModel.request_body(model, messages, opts)
      assert error.type == :unsupported_model_param
      assert :store in error.details.params
      assert error.details.stateless == true
    end
  end

  test "Responses validates instructions and reasoning effort" do
    model = ResponsesModel.new()
    messages = [Message.user("hello")]

    for instructions <- [123, ""] do
      assert {:error, error} =
               ResponsesModel.request_body(model, messages, instructions: instructions)

      assert error.type == :invalid_request
      assert error.details.param == :instructions
    end

    for effort <- [:none, :minimal, :low, :medium, :high, :xhigh, :max] do
      assert {:ok, body} =
               ResponsesModel.request_body(model, messages, reasoning_effort: effort)

      assert body["reasoning"] == %{"effort" => Atom.to_string(effort)}
    end

    assert {:error, error} =
             ResponsesModel.request_body(model, messages, reasoning_effort: :bananas)

    assert error.type == :invalid_request
    assert error.details.param == :reasoning
    assert error.details.effort == "bananas"
  end

  test "Responses honors model-level top_logprobs with per-call precedence" do
    model = ResponsesModel.new(top_logprobs: 2)
    messages = [Message.user("hello")]

    assert {:ok, body} = ResponsesModel.request_body(model, messages)
    assert body["top_logprobs"] == 2

    assert {:ok, overridden} = ResponsesModel.request_body(model, messages, top_logprobs: 4)
    assert overridden["top_logprobs"] == 4
  end

  test "Responses rejects unknown and media input items" do
    model = ResponsesModel.new()

    for item <- [
          %{"type" => "unknown_future_item"},
          %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_image"}]},
          %{}
        ] do
      assert {:error, error} = ResponsesModel.request_body(model, [], input_items: [item])
      assert error.type == :unsupported_feature
    end
  end

  test "Responses requires unique call ids and exactly one function output per call" do
    model = ResponsesModel.new()
    call = %{"type" => "function_call", "call_id" => "call_1", "name" => "lookup", "arguments" => "{}"}
    output = %{"type" => "function_call_output", "call_id" => "call_1", "output" => "ok"}

    assert {:error, error} = ResponsesModel.request_body(model, [], input_items: [call])
    assert error.message =~ "exactly one output"

    assert {:ok, body} = ResponsesModel.request_body(model, [], input_items: [call, output])
    assert body["input"] == [call, output]

    assert {:error, error} =
             ResponsesModel.request_body(model, [], input_items: [call, call, output])

    assert error.message =~ "unique"

    assert {:error, error} =
             ResponsesModel.request_body(model, [],
               input_items: [%{"type" => "function_call", "call_id" => "", "name" => "lookup"}]
             )

    assert error.message =~ "nonempty"
  end

  test "Responses validates required function and custom call payload fields" do
    model = ResponsesModel.new()

    valid_call = %{
      "type" => "function_call",
      "call_id" => "call_1",
      "name" => "lookup",
      "arguments" => "{}"
    }

    valid_output = %{
      "type" => "function_call_output",
      "call_id" => "call_1",
      "output" => "ok"
    }

    for {param, call, output} <- [
          {:name, Map.delete(valid_call, "name"), valid_output},
          {:arguments, Map.delete(valid_call, "arguments"), valid_output},
          {:output, valid_call, Map.delete(valid_output, "output")}
        ] do
      assert {:error, error} =
               ResponsesModel.request_body(model, [], input_items: [call, output])

      assert error.type == :invalid_request
      assert error.details.param == param
    end

    tool = Tools.apply_patch()

    custom_call = %{
      "type" => "custom_tool_call",
      "call_id" => "patch_1",
      "name" => "apply_patch",
      "input" => "*** Begin Patch"
    }

    custom_output = %{
      "type" => "custom_tool_call_output",
      "call_id" => "patch_1",
      "output" => "Done!"
    }

    for {param, call, output} <- [
          {:input, Map.delete(custom_call, "input"), custom_output},
          {:output, custom_call, Map.delete(custom_output, "output")}
        ] do
      assert {:error, error} =
               ResponsesModel.request_body(model, [],
                 tools: [tool],
                 input_items: [call, output]
               )

      assert error.type == :invalid_request
      assert error.details.param == param
    end
  end

  test "Responses replays DeepSeek's custom apply_patch extension and pairs outputs" do
    model = ResponsesModel.new()
    tool = Tools.apply_patch(format: %{type: "grammar", syntax: "lark", definition: "start: /.+/"})

    call = %{
      "type" => "custom_tool_call",
      "call_id" => "patch_1",
      "name" => "apply_patch",
      "input" => "*** Begin Patch"
    }

    output = %{
      "type" => "custom_tool_call_output",
      "call_id" => "patch_1",
      "output" => "Done!"
    }

    assert {:ok, body} =
             ResponsesModel.request_body(model, [],
               tools: [tool],
               input_items: [call, output],
               reasoning: %{effort: "none"},
               tool_choice: %{type: "custom", name: "apply_patch"}
             )

    assert body["tools"] == [tool]
    assert body["input"] == [call, output]

    assert {:error, error} =
             ResponsesModel.request_body(model, [],
               input_items: [call, output],
               reasoning: %{effort: "none"}
             )

    assert error.message =~ "apply_patch"
  end

  test "Responses custom apply_patch output round-trips into the next request" do
    model = ResponsesModel.new()
    tool = Tools.apply_patch()

    response = %{
      "id" => "resp_1",
      "model" => "deepseek-v4-flash",
      "status" => "completed",
      "output" => [
        %{
          "type" => "custom_tool_call",
          "id" => "ct_1",
          "call_id" => "patch_1",
          "name" => "apply_patch",
          "input" => "*** Begin Patch",
          "status" => "completed"
        }
      ]
    }

    assert {:ok, previous} = Messages.responses_to_message(response)

    output = %{
      "type" => "custom_tool_call_output",
      "call_id" => "patch_1",
      "output" => "Done!"
    }

    assert {:ok, body} =
             ResponsesModel.request_body(model, [previous],
               tools: [tool],
               input_items: [output]
             )

    assert [replayed_call, ^output] = body["input"]
    assert replayed_call["type"] == "custom_tool_call"
    assert replayed_call["call_id"] == "patch_1"
    assert replayed_call["name"] == "apply_patch"
    assert replayed_call["input"] == "*** Begin Patch"
  end

  test "Responses named function and web-search choices must reference declared tools" do
    model = ResponsesModel.new()
    message = [Message.user("hello")]

    assert {:error, error} =
             ResponsesModel.request_body(model, message,
               tools: [@function_tool],
               tool_choice: %{type: "function", name: "lookup"}
             )

    assert error.type == :unsupported_model_param
    assert error.details.required == %{reasoning: %{effort: "none"}}

    assert {:ok, _body} =
             ResponsesModel.request_body(model, message,
               tools: [@function_tool],
               reasoning: %{effort: "none"},
               tool_choice: %{type: "function", name: "lookup"}
             )

    assert {:error, error} =
             ResponsesModel.request_body(model, message,
               tools: [@function_tool],
               reasoning: %{effort: "none"},
               tool_choice: %{type: "function", name: "missing"}
             )

    assert error.message =~ "declared tool"

    web_search = Tools.web_search()

    assert {:ok, _body} =
             ResponsesModel.request_body(model, message,
               tools: [web_search],
               tool_choice: %{type: "web_search"}
             )

    assert {:error, error} =
             ResponsesModel.request_body(model, message, tool_choice: %{type: "web_search"})

    assert error.message =~ "declared tool"
  end

  test "Responses forced custom choice requires reasoning effort none while auto remains available" do
    model = ResponsesModel.new()
    messages = [Message.user("apply a patch")]
    tool = Tools.apply_patch()

    assert {:error, error} =
             ResponsesModel.request_body(model, messages,
               tools: [tool],
               tool_choice: %{type: "custom", name: "apply_patch"}
             )

    assert error.type == :unsupported_model_param
    assert error.details.required == %{reasoning: %{effort: "none"}}

    assert {:ok, forced_body} =
             ResponsesModel.request_body(model, messages,
               tools: [tool],
               reasoning: %{effort: "none"},
               tool_choice: %{type: "custom", name: "apply_patch"}
             )

    assert forced_body["reasoning"] == %{"effort" => "none"}

    assert {:ok, auto_body} =
             ResponsesModel.request_body(model, messages,
               tools: [tool],
               tool_choice: :auto
             )

    assert auto_body["tool_choice"] == "auto"
    refute Map.has_key?(auto_body, "reasoning")
  end
end
