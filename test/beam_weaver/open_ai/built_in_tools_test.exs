defmodule BeamWeaver.OpenAI.BuiltInToolsTest do
  use ExUnit.Case

  alias BeamWeaver.Core.ChatModel, as: CoreChatModel
  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.ToolCall
  alias BeamWeaver.OpenAI.ChatModel
  alias BeamWeaver.OpenAI.Responses
  alias BeamWeaver.OpenAI.ToolCalling

  test "web search request shape and output blocks round-trip through replay" do
    request_body = %{
      "model" => "gpt-5.5",
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => "What was a positive news story from today?"
        }
      ],
      "stream" => false,
      "tools" => [%{"type" => "web_search_preview"}]
    }

    response_body = %{
      "id" => "resp_web_search",
      "output" => [
        %{
          "id" => "ws_123",
          "type" => "web_search_call",
          "status" => "completed",
          "action" => %{"type" => "search", "query" => "positive news stories today"}
        },
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [
            %{
              "type" => "output_text",
              "text" => "A city expanded its cool-roof program.",
              "annotations" => [
                %{"type" => "url_citation", "url" => "https://example.test/news"}
              ]
            }
          ]
        }
      ]
    }

    model = replay_model(write_gzip_cassette(request_body, response_body))

    assert {:ok, response} =
             CoreChatModel.invoke(
               model,
               [Message.user("What was a positive news story from today?")],
               tools: [ToolCalling.web_search()]
             )

    assert Message.text(response) == "A city expanded its cool-roof program."

    assert [
             %{
               type: :web_search_call,
               action: %{"query" => "positive news stories today"}
             },
             %{type: :text, annotations: [%{"type" => "url_citation"}]}
           ] = response.content
  end

  test "apply_patch request shape and output items round-trip through replay" do
    request_body = %{
      "model" => "gpt-5.5",
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => "Patch the typo."
        }
      ],
      "stream" => false,
      "tools" => [%{"type" => "apply_patch"}]
    }

    response_body = %{
      "id" => "resp_apply_patch",
      "output" => [
        %{
          "type" => "apply_patch_call",
          "id" => "apc_123",
          "status" => "completed",
          "patch" => "*** Begin Patch\n*** End Patch\n"
        },
        %{
          "type" => "apply_patch_call_output",
          "id" => "apco_123",
          "status" => "completed",
          "output" => "Success."
        },
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => "Patched."}]
        }
      ]
    }

    model = replay_model(write_gzip_cassette(request_body, response_body), model: "gpt-5.5")

    assert {:ok, response} =
             CoreChatModel.invoke(model, [Message.user("Patch the typo.")], tools: [ToolCalling.apply_patch()])

    assert [
             %ContentBlock.Unknown{
               provider_type: "apply_patch_call",
               value: %{patch: "*** Begin Patch\n*** End Patch\n"}
             },
             %ContentBlock.Unknown{
               provider_type: "apply_patch_call_output",
               value: %{output: "Success."}
             },
             %{type: :text, text: "Patched."}
           ] = response.content
  end

  test "reasoning and context-management request options are preserved" do
    request_body = %{
      "model" => "gpt-5-mini",
      "input" => [
        %{"type" => "message", "role" => "user", "content" => "Hello"}
      ],
      "stream" => false,
      "reasoning" => %{"effort" => "low", "summary" => "auto"},
      "context_management" => [
        %{"type" => "compaction", "compact_threshold" => 10_000}
      ],
      "include" => ["reasoning.encrypted_content"]
    }

    response_body = %{
      "id" => "resp_reasoning",
      "output" => [
        %{"id" => "rs_123", "type" => "reasoning", "summary" => []},
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => "Hello."}]
        }
      ]
    }

    model = replay_model(write_gzip_cassette(request_body, response_body), model: "gpt-5-mini")

    assert {:ok, response} =
             CoreChatModel.invoke(model, [Message.user("Hello")],
               reasoning: %{effort: :low, summary: :auto},
               context_management: [%{type: :compaction, compact_threshold: 10_000}],
               include: ["reasoning.encrypted_content"]
             )

    assert Message.text(response) == "Hello."
    assert response.metadata.reasoning["id"] == "rs_123"
    assert [%{type: :reasoning}, %{type: :text}] = response.content
  end

  test "MCP approval input items can be sent without being wrapped as messages" do
    mcp_tool =
      ToolCalling.mcp("deepwiki", "https://mcp.deepwiki.com/mcp",
        require_approval: %{always: %{tool_names: ["read_wiki_structure"]}}
      )

    request_body = %{
      "model" => "gpt-5-mini",
      "input" => [
        %{
          "type" => "mcp_approval_response",
          "approve" => true,
          "approval_request_id" => "mcpr_123"
        }
      ],
      "stream" => false,
      "previous_response_id" => "resp_previous",
      "tools" => [mcp_tool]
    }

    response_body = %{
      "output" => [
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [
            %{"type" => "output_text", "text" => "MCP approval accepted."}
          ]
        }
      ]
    }

    model = replay_model(write_gzip_cassette(request_body, response_body), model: "gpt-5-mini")

    assert {:ok, response} =
             CoreChatModel.invoke(model, [],
               input_items: [
                 %{
                   type: :mcp_approval_response,
                   approve: true,
                   approval_request_id: "mcpr_123"
                 }
               ],
               previous_response_id: "resp_previous",
               tools: [mcp_tool]
             )

    assert Message.text(response) == "MCP approval accepted."
  end

  test "tool search request shape preserves deferred function tools" do
    weather_tool =
      ToolCalling.function(
        BeamWeaver.Core.Tool.from_function!(
          name: "get_weather",
          description: "Get the current weather for a location.",
          input_schema: %{
            type: "object",
            properties: %{location: %{type: "string"}},
            required: [:location]
          },
          handler: fn input, _opts -> input end
        ),
        defer_loading: true
      )

    request_body = %{
      "model" => "gpt-5.4",
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => "What's the weather in San Francisco?"
        }
      ],
      "stream" => false,
      "tools" => [
        weather_tool,
        %{"type" => "tool_search"}
      ]
    }

    response_body = %{
      "output" => [
        %{
          "type" => "tool_search_call",
          "id" => "tsc_123",
          "arguments" => %{"paths" => ["get_weather"]},
          "execution" => "server",
          "status" => "completed"
        },
        %{
          "type" => "tool_search_output",
          "id" => "tso_123",
          "execution" => "server",
          "status" => "completed",
          "tools" => [weather_tool]
        },
        %{
          "type" => "function_call",
          "id" => "fc_123",
          "call_id" => "call_weather",
          "name" => "get_weather",
          "arguments" => ~s({"location":"San Francisco"})
        }
      ]
    }

    model = replay_model(write_gzip_cassette(request_body, response_body), model: "gpt-5.4")

    assert {:ok, response} =
             CoreChatModel.invoke(
               model,
               [Message.user("What's the weather in San Francisco?")],
               tools: [weather_tool, ToolCalling.tool_search()]
             )

    assert [
             %{type: :tool_search_call},
             %{type: :tool_search_output},
             %{
               type: :tool_call,
               call_id: "call_weather",
               name: "get_weather",
               arguments: ~s({"location":"San Francisco"})
             }
           ] = response.content

    assert [
             %ToolCall{
               call_id: "call_weather",
               name: "get_weather",
               args: %{"location" => "San Francisco"}
             }
           ] = response.tool_calls
  end

  test "streamed tool-search loop preserves search output and follow-up function output" do
    weather_tool =
      ToolCalling.function(
        BeamWeaver.Core.Tool.from_function!(
          name: "get_weather",
          description: "Get the current weather for a location.",
          input_schema: %{
            type: "object",
            properties: %{location: %{type: "string"}},
            required: [:location],
            additionalProperties: false
          },
          handler: fn input, _opts -> input end
        ),
        defer_loading: true,
        strict: true
      )

    recipe_tool =
      ToolCalling.function(
        BeamWeaver.Core.Tool.from_function!(
          name: "get_recipe",
          description: "Get a recipe for chicken soup.",
          input_schema: %{
            type: "object",
            properties: %{query: %{type: "string"}},
            required: [:query],
            additionalProperties: false
          },
          handler: fn input, _opts -> input end
        ),
        defer_loading: true,
        strict: true
      )

    prompt = "What's the weather in San Francisco?"
    tools = [weather_tool, recipe_tool, ToolCalling.tool_search()]

    first_request = %{
      "model" => "gpt-5.4",
      "input" => [Responses.message(:user, prompt)],
      "stream" => true,
      "tools" => tools
    }

    first_response = """
    event: response.created
    data: {"type":"response.created","response":{"id":"resp_tool_search_1","model":"gpt-5.4","output":[]}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"tool_search_call","id":"tsc_1","status":"in_progress","arguments":{},"execution":"server"}}

    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":0,"item":{"type":"tool_search_call","id":"tsc_1","status":"completed","arguments":{"paths":["get_weather"]},"execution":"server"}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":1,"item":{"type":"tool_search_output","id":"tso_1","status":"in_progress","execution":"server","tools":[]}}

    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":1,"item":{"type":"tool_search_output","id":"tso_1","status":"completed","execution":"server","tools":[{"type":"function","name":"get_weather","description":"Get the current weather for a location.","parameters":{"type":"object","properties":{"location":{"type":"string"}},"required":["location"],"additionalProperties":false},"defer_loading":true,"strict":true}]}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":2,"item":{"type":"function_call","id":"fc_1","call_id":"call_weather","name":"get_weather","namespace":"get_weather","arguments":""}}

    event: response.function_call_arguments.delta
    data: {"type":"response.function_call_arguments.delta","output_index":2,"item_id":"fc_1","delta":"{\\\"location\\\":"}

    event: response.function_call_arguments.delta
    data: {"type":"response.function_call_arguments.delta","output_index":2,"item_id":"fc_1","delta":"\\\"San Francisco\\\"}"}

    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":2,"item":{"type":"function_call","id":"fc_1","call_id":"call_weather","name":"get_weather","namespace":"get_weather","arguments":"{\\\"location\\\":\\\"San Francisco\\\"}","status":"completed"}}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_tool_search_1","model":"gpt-5.4","output":[]}}

    data: [DONE]
    """

    second_request = %{
      "model" => "gpt-5.4",
      "input" => [
        Responses.message(:user, prompt),
        %{
          "type" => "tool_search_call",
          "id" => "tsc_1",
          "status" => "completed",
          "arguments" => %{"paths" => ["get_weather"]},
          "execution" => "server"
        },
        %{
          "type" => "tool_search_output",
          "id" => "tso_1",
          "status" => "completed",
          "execution" => "server",
          "tools" => [weather_tool]
        },
        %{
          "type" => "function_call",
          "id" => "fc_1",
          "call_id" => "call_weather",
          "name" => "get_weather",
          "namespace" => "get_weather",
          "arguments" => ~s({"location":"San Francisco"}),
          "status" => "completed"
        },
        Responses.function_call_output(
          "call_weather",
          "The weather in San Francisco is sunny and 72F"
        )
      ],
      "stream" => true,
      "tools" => tools
    }

    second_response = """
    event: response.created
    data: {"type":"response.created","response":{"id":"resp_tool_search_2","model":"gpt-5.4","output":[]}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_1","role":"assistant","content":[]}}

    event: response.content_part.added
    data: {"type":"response.content_part.added","output_index":0,"item_id":"msg_1","content_index":0,"part":{"type":"output_text","text":""}}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","output_index":0,"item_id":"msg_1","content_index":0,"delta":"It is sunny and 72F."}

    event: response.output_text.done
    data: {"type":"response.output_text.done","output_index":0,"item_id":"msg_1","content_index":0,"text":"It is sunny and 72F."}

    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_1","role":"assistant","status":"completed","content":[{"type":"output_text","text":"It is sunny and 72F."}]}}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_tool_search_2","model":"gpt-5.4","output":[]}}

    data: [DONE]
    """

    model =
      replay_model(
        write_gzip_cassette([
          {first_request, first_response, content_type: "text/event-stream"},
          {second_request, second_response, content_type: "text/event-stream"}
        ]),
        model: "gpt-5.4"
      )

    assert {:ok, first} =
             ChatModel.stream_response(model, [Message.user(prompt)], tools: tools)

    assert [%{type: :tool_search_call}, %{type: :tool_search_output} | _rest] =
             first.content

    assert [
             %ToolCall{
               call_id: "call_weather",
               name: "get_weather",
               args: %{"location" => "San Francisco"}
             }
           ] = first.tool_calls

    assert [
             %{"type" => "tool_search_call"},
             %{"type" => "tool_search_output"},
             %{"type" => "function_call"}
           ] =
             first.metadata.output |> Enum.map(&Map.take(&1, ["type"]))

    input_items =
      [Responses.message(:user, prompt)] ++
        Responses.output_items(first) ++
        [
          Responses.function_call_output(
            List.first(first.tool_calls),
            "The weather in San Francisco is sunny and 72F"
          )
        ]

    assert {:ok, second} =
             ChatModel.stream_response(model, [], input_items: input_items, tools: tools)

    assert Message.text(second) == "It is sunny and 72F."
  end

  test "phase agent loop preserves function output and phase-tagged text" do
    weather_tool =
      ToolCalling.function(
        BeamWeaver.Core.Tool.from_function!(
          name: "get_weather",
          description: "Get the weather at a location.",
          input_schema: %{
            type: "object",
            properties: %{location: %{type: "string"}},
            required: [:location]
          },
          handler: fn _input, _opts -> "It's sunny." end
        )
      )

    prompt =
      "What's the weather in the oldest major city in the US? State your answer and then generate a tool call this turn."

    tools = [weather_tool]
    reasoning = %{"effort" => "medium", "summary" => "auto"}

    first_request = %{
      "model" => "gpt-5.4",
      "input" => [Responses.message(:user, prompt)],
      "stream" => false,
      "tools" => tools,
      "reasoning" => reasoning,
      "text" => %{"verbosity" => "high"}
    }

    first_response = %{
      "id" => "resp_phase_sync_1",
      "output" => [
        %{"type" => "reasoning", "id" => "rs_phase_sync", "summary" => []},
        %{
          "type" => "message",
          "id" => "msg_phase_sync_1",
          "role" => "assistant",
          "content" => [
            %{
              "type" => "output_text",
              "text" => "St. Augustine is the oldest major city.",
              "phase" => "commentary"
            }
          ]
        },
        %{
          "type" => "function_call",
          "id" => "fc_phase_sync",
          "call_id" => "call_phase_weather",
          "name" => "get_weather",
          "arguments" => ~s({"location":"St. Augustine, FL"})
        }
      ]
    }

    second_request = %{
      "model" => "gpt-5.4",
      "input" => [
        Responses.message(:user, prompt),
        %{"type" => "reasoning", "id" => "rs_phase_sync", "summary" => []},
        %{
          "type" => "message",
          "id" => "msg_phase_sync_1",
          "role" => "assistant",
          "content" => [
            %{
              "type" => "output_text",
              "text" => "St. Augustine is the oldest major city.",
              "phase" => "commentary"
            }
          ]
        },
        %{
          "type" => "function_call",
          "id" => "fc_phase_sync",
          "call_id" => "call_phase_weather",
          "name" => "get_weather",
          "arguments" => ~s({"location":"St. Augustine, FL"})
        },
        Responses.function_call_output("call_phase_weather", "It's sunny.")
      ],
      "stream" => false,
      "tools" => tools,
      "reasoning" => reasoning,
      "text" => %{"verbosity" => "high"}
    }

    second_response = %{
      "id" => "resp_phase_sync_2",
      "output" => [
        %{
          "type" => "message",
          "id" => "msg_phase_sync_2",
          "role" => "assistant",
          "content" => [
            %{
              "type" => "output_text",
              "text" => "St. Augustine, FL is sunny.",
              "phase" => "final_answer"
            }
          ]
        }
      ]
    }

    model =
      replay_model(
        write_gzip_cassette([
          {first_request, first_response},
          {second_request, second_response}
        ]),
        model: "gpt-5.4"
      )

    opts = [tools: tools, reasoning: %{effort: :medium, summary: :auto}, verbosity: :high]

    assert {:ok, first} = CoreChatModel.invoke(model, [Message.user(prompt)], opts)

    assert [
             %{type: :reasoning},
             %{
               type: :text,
               text: "St. Augustine is the oldest major city.",
               phase: "commentary"
             },
             %{
               type: :tool_call,
               call_id: "call_phase_weather",
               name: "get_weather",
               arguments: ~s({"location":"St. Augustine, FL"})
             }
           ] = first.content

    assert [%ToolCall{call_id: "call_phase_weather"}] = first.tool_calls

    input_items =
      [Responses.message(:user, prompt)] ++
        Responses.output_items(first) ++
        [Responses.function_call_output(List.first(first.tool_calls), "It's sunny.")]

    assert {:ok, second} =
             CoreChatModel.invoke(model, [], Keyword.put(opts, :input_items, input_items))

    assert [
             %{
               type: :text,
               text: "St. Augustine, FL is sunny.",
               phase: "final_answer"
             }
           ] = second.content
  end

  test "streamed agent loop preserves reasoning, tool call, and follow-up function output" do
    weather_tool =
      ToolCalling.function(
        BeamWeaver.Core.Tool.from_function!(
          name: "get_weather",
          description: "Get the weather for a location.",
          input_schema: %{
            type: "object",
            properties: %{location: %{type: "string"}},
            required: [:location]
          },
          handler: fn _input, _opts -> "It's sunny." end
        )
      )

    prompt = "What is the weather in San Francisco, CA?"
    tools = [weather_tool]
    reasoning = %{"effort" => "medium", "summary" => "auto"}

    first_request = %{
      "model" => "gpt-5.5",
      "input" => [Responses.message(:user, prompt)],
      "stream" => true,
      "reasoning" => reasoning,
      "tools" => tools
    }

    first_response = """
    event: response.created
    data: {"type":"response.created","response":{"id":"resp_agent_1","model":"gpt-5.5","output":[]}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"reasoning","id":"rs_agent","summary":[]}}

    event: response.reasoning_summary_part.added
    data: {"type":"response.reasoning_summary_part.added","output_index":0,"item_id":"rs_agent","summary_index":0,"part":{"type":"summary_text","text":""}}

    event: response.reasoning_summary_text.delta
    data: {"type":"response.reasoning_summary_text.delta","output_index":0,"item_id":"rs_agent","summary_index":0,"delta":"Need current weather."}

    event: response.reasoning_summary_text.done
    data: {"type":"response.reasoning_summary_text.done","output_index":0,"item_id":"rs_agent","summary_index":0,"text":"Need current weather."}

    event: response.reasoning_summary_part.done
    data: {"type":"response.reasoning_summary_part.done","output_index":0,"item_id":"rs_agent","summary_index":0,"part":{"type":"summary_text","text":"Need current weather."}}

    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs_agent","summary":[{"type":"summary_text","text":"Need current weather."}]}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","id":"fc_agent","call_id":"call_weather","name":"get_weather","arguments":""}}

    event: response.function_call_arguments.delta
    data: {"type":"response.function_call_arguments.delta","output_index":1,"item_id":"fc_agent","delta":"{\\\"location\\\":"}

    event: response.function_call_arguments.delta
    data: {"type":"response.function_call_arguments.delta","output_index":1,"item_id":"fc_agent","delta":"\\\"San Francisco, CA\\\"}"}

    event: response.function_call_arguments.done
    data: {"type":"response.function_call_arguments.done","output_index":1,"item_id":"fc_agent","name":"get_weather","arguments":"{\\\"location\\\":\\\"San Francisco, CA\\\"}"}

    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","id":"fc_agent","call_id":"call_weather","name":"get_weather","arguments":"{\\\"location\\\":\\\"San Francisco, CA\\\"}","status":"completed"}}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_agent_1","model":"gpt-5.5","output":[]}}

    data: [DONE]
    """

    second_request = %{
      "model" => "gpt-5.5",
      "input" => [
        Responses.message(:user, prompt),
        %{
          "type" => "reasoning",
          "id" => "rs_agent",
          "summary" => [%{"type" => "summary_text", "text" => "Need current weather."}]
        },
        %{
          "type" => "function_call",
          "id" => "fc_agent",
          "call_id" => "call_weather",
          "name" => "get_weather",
          "arguments" => ~s({"location":"San Francisco, CA"}),
          "status" => "completed"
        },
        Responses.function_call_output("call_weather", "It's sunny.")
      ],
      "stream" => true,
      "reasoning" => reasoning,
      "tools" => tools
    }

    second_response = """
    event: response.created
    data: {"type":"response.created","response":{"id":"resp_agent_2","model":"gpt-5.5","output":[]}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_agent","role":"assistant","content":[]}}

    event: response.content_part.added
    data: {"type":"response.content_part.added","output_index":0,"item_id":"msg_agent","content_index":0,"part":{"type":"output_text","text":""}}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","output_index":0,"item_id":"msg_agent","content_index":0,"delta":"It's sunny in San Francisco, CA."}

    event: response.output_text.done
    data: {"type":"response.output_text.done","output_index":0,"item_id":"msg_agent","content_index":0,"text":"It's sunny in San Francisco, CA."}

    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_agent","role":"assistant","status":"completed","content":[{"type":"output_text","text":"It's sunny in San Francisco, CA."}]}}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_agent_2","model":"gpt-5.5","output":[]}}

    data: [DONE]
    """

    model =
      replay_model(
        write_gzip_cassette([
          {first_request, first_response, content_type: "text/event-stream"},
          {second_request, second_response, content_type: "text/event-stream"}
        ]),
        model: "gpt-5.5"
      )

    assert {:ok, events} =
             ChatModel.stream_events(model, [Message.user(prompt)],
               reasoning: %{effort: :medium, summary: :auto},
               tools: tools
             )

    assert Enum.any?(
             events,
             &match?(
               %{
                 "event" => "content-block-finish",
                 "content" => %{"type" => "reasoning", "reasoning" => "Need current weather."}
               },
               &1
             )
           )

    assert Enum.any?(
             events,
             &match?(
               %{
                 "event" => "content-block-finish",
                 "content" => %{
                   "type" => "tool_call",
                   "id" => "call_weather",
                   "args" => %{"location" => "San Francisco, CA"}
                 }
               },
               &1
             )
           )

    assert {:ok, first} =
             ChatModel.stream_response(model, [Message.user(prompt)],
               reasoning: %{effort: :medium, summary: :auto},
               tools: tools
             )

    assert [
             %ToolCall{
               call_id: "call_weather",
               name: "get_weather",
               args: %{"location" => "San Francisco, CA"}
             }
           ] = first.tool_calls

    assert [
             %{"type" => "reasoning"},
             %{"type" => "function_call"}
           ] =
             first.metadata.output |> Enum.map(&Map.take(&1, ["type"]))

    input_items =
      [Responses.message(:user, prompt)] ++
        Responses.output_items(first) ++
        [Responses.function_call_output(List.first(first.tool_calls), "It's sunny.")]

    assert {:ok, second} =
             ChatModel.stream_response(model, [],
               input_items: input_items,
               reasoning: %{effort: :medium, summary: :auto},
               tools: tools
             )

    assert Message.text(second) == "It's sunny in San Francisco, CA."
  end

  test "streamed compaction output item survives the next Responses turn" do
    context_management = [%{type: :compaction, compact_threshold: 10_000}]
    context_management_request = [%{"type" => "compaction", "compact_threshold" => 10_000}]

    first_prompt = "Generate a one-sentence summary of document A."
    second_prompt = "Generate a one-sentence summary of document B."
    third_prompt = "What are we talking about?"

    first_request = %{
      "model" => "gpt-5.5",
      "input" => [Responses.message(:user, first_prompt)],
      "stream" => true,
      "context_management" => context_management_request
    }

    first_response = """
    event: response.created
    data: {"type":"response.created","response":{"id":"resp_compact_1","model":"gpt-5.5","output":[]}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_compact_1","role":"assistant","content":[]}}

    event: response.content_part.added
    data: {"type":"response.content_part.added","output_index":0,"item_id":"msg_compact_1","content_index":0,"part":{"type":"output_text","text":""}}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","output_index":0,"item_id":"msg_compact_1","content_index":0,"delta":"Document A is about architecture."}

    event: response.output_text.done
    data: {"type":"response.output_text.done","output_index":0,"item_id":"msg_compact_1","content_index":0,"text":"Document A is about architecture."}

    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_compact_1","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Document A is about architecture."}]}}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_compact_1","model":"gpt-5.5","output":[]}}

    data: [DONE]
    """

    second_request = %{
      "model" => "gpt-5.5",
      "input" => [
        Responses.message(:user, first_prompt),
        %{
          "type" => "message",
          "id" => "msg_compact_1",
          "role" => "assistant",
          "status" => "completed",
          "content" => [
            %{"type" => "output_text", "text" => "Document A is about architecture."}
          ]
        },
        Responses.message(:user, second_prompt)
      ],
      "stream" => true,
      "context_management" => context_management_request
    }

    second_response = """
    event: response.created
    data: {"type":"response.created","response":{"id":"resp_compact_2","model":"gpt-5.5","output":[]}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"compaction","id":"cmp_1","status":"in_progress"}}

    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":0,"item":{"type":"compaction","id":"cmp_1","status":"completed","input_tokens":12000,"output_tokens":800}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":1,"item":{"type":"message","id":"msg_compact_2","role":"assistant","content":[]}}

    event: response.content_part.added
    data: {"type":"response.content_part.added","output_index":1,"item_id":"msg_compact_2","content_index":0,"part":{"type":"output_text","text":""}}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","output_index":1,"item_id":"msg_compact_2","content_index":0,"delta":"Document B is about runtime behavior."}

    event: response.output_text.done
    data: {"type":"response.output_text.done","output_index":1,"item_id":"msg_compact_2","content_index":0,"text":"Document B is about runtime behavior."}

    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":1,"item":{"type":"message","id":"msg_compact_2","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Document B is about runtime behavior."}]}}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_compact_2","model":"gpt-5.5","output":[]}}

    data: [DONE]
    """

    third_request = %{
      "model" => "gpt-5.5",
      "input" => [
        Responses.message(:user, first_prompt),
        %{
          "type" => "message",
          "id" => "msg_compact_1",
          "role" => "assistant",
          "status" => "completed",
          "content" => [
            %{"type" => "output_text", "text" => "Document A is about architecture."}
          ]
        },
        Responses.message(:user, second_prompt),
        %{
          "type" => "compaction",
          "id" => "cmp_1",
          "status" => "completed",
          "input_tokens" => 12_000,
          "output_tokens" => 800
        },
        %{
          "type" => "message",
          "id" => "msg_compact_2",
          "role" => "assistant",
          "status" => "completed",
          "content" => [
            %{"type" => "output_text", "text" => "Document B is about runtime behavior."}
          ]
        },
        Responses.message(:user, third_prompt)
      ],
      "stream" => true,
      "context_management" => context_management_request
    }

    third_response = """
    event: response.created
    data: {"type":"response.created","response":{"id":"resp_compact_3","model":"gpt-5.5","output":[]}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_compact_3","role":"assistant","content":[]}}

    event: response.content_part.added
    data: {"type":"response.content_part.added","output_index":0,"item_id":"msg_compact_3","content_index":0,"part":{"type":"output_text","text":""}}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","output_index":0,"item_id":"msg_compact_3","content_index":0,"delta":"We are talking about architecture and runtime behavior."}

    event: response.output_text.done
    data: {"type":"response.output_text.done","output_index":0,"item_id":"msg_compact_3","content_index":0,"text":"We are talking about architecture and runtime behavior."}

    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_compact_3","role":"assistant","status":"completed","content":[{"type":"output_text","text":"We are talking about architecture and runtime behavior."}]}}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_compact_3","model":"gpt-5.5","output":[]}}

    data: [DONE]
    """

    model =
      replay_model(
        write_gzip_cassette([
          {first_request, first_response, content_type: "text/event-stream"},
          {second_request, second_response, content_type: "text/event-stream"},
          {third_request, third_response, content_type: "text/event-stream"}
        ]),
        model: "gpt-5.5"
      )

    assert {:ok, first} =
             ChatModel.stream_response(model, [Message.user(first_prompt)], context_management: context_management)

    second_input_items =
      [Responses.message(:user, first_prompt)] ++
        Responses.output_items(first) ++
        [Responses.message(:user, second_prompt)]

    assert {:ok, second} =
             ChatModel.stream_response(model, [],
               input_items: second_input_items,
               context_management: context_management
             )

    assert %{
             "type" => "compaction",
             "id" => "cmp_1",
             "status" => "completed",
             "input_tokens" => 12_000
           } = Responses.first_output_item(second, "compaction")

    third_input_items =
      second_input_items ++
        Responses.output_items(second) ++
        [Responses.message(:user, third_prompt)]

    assert {:ok, third} =
             ChatModel.stream_response(model, [],
               input_items: third_input_items,
               context_management: context_management
             )

    assert Message.text(third) == "We are talking about architecture and runtime behavior."
  end

  test "streamed phase output preserves commentary and final answer phases" do
    weather_tool =
      ToolCalling.function(
        BeamWeaver.Core.Tool.from_function!(
          name: "get_weather",
          description: "Get the weather at a location.",
          input_schema: %{
            type: "object",
            properties: %{location: %{type: "string"}},
            required: [:location]
          },
          handler: fn _input, _opts -> "It's sunny." end
        )
      )

    prompt =
      "What's the weather in the oldest major city in the US? State your answer and then generate a tool call this turn."

    tools = [weather_tool]
    reasoning = %{"effort" => "medium", "summary" => "auto"}

    first_request = %{
      "model" => "gpt-5.4",
      "input" => [Responses.message(:user, prompt)],
      "stream" => true,
      "tools" => tools,
      "reasoning" => reasoning,
      "text" => %{"verbosity" => "high"}
    }

    first_response = """
    event: response.created
    data: {"type":"response.created","response":{"id":"resp_phase_1","model":"gpt-5.4","output":[]}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"reasoning","id":"rs_phase","summary":[]}}

    event: response.reasoning_summary_part.added
    data: {"type":"response.reasoning_summary_part.added","output_index":0,"item_id":"rs_phase","summary_index":0,"part":{"type":"summary_text","text":""}}

    event: response.reasoning_summary_text.delta
    data: {"type":"response.reasoning_summary_text.delta","output_index":0,"item_id":"rs_phase","summary_index":0,"delta":"Identified the city."}

    event: response.reasoning_summary_text.done
    data: {"type":"response.reasoning_summary_text.done","output_index":0,"item_id":"rs_phase","summary_index":0,"text":"Identified the city."}

    event: response.reasoning_summary_part.done
    data: {"type":"response.reasoning_summary_part.done","output_index":0,"item_id":"rs_phase","summary_index":0,"part":{"type":"summary_text","text":"Identified the city."}}

    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs_phase","summary":[{"type":"summary_text","text":"Identified the city."}]}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":1,"item":{"type":"message","id":"msg_phase_1","role":"assistant","content":[]}}

    event: response.content_part.added
    data: {"type":"response.content_part.added","output_index":1,"item_id":"msg_phase_1","content_index":0,"part":{"type":"output_text","text":"","phase":"commentary"}}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","output_index":1,"item_id":"msg_phase_1","content_index":0,"delta":"St. Augustine is the oldest major city."}

    event: response.output_text.done
    data: {"type":"response.output_text.done","output_index":1,"item_id":"msg_phase_1","content_index":0,"text":"St. Augustine is the oldest major city."}

    event: response.content_part.done
    data: {"type":"response.content_part.done","output_index":1,"item_id":"msg_phase_1","content_index":0,"part":{"type":"output_text","text":"St. Augustine is the oldest major city.","phase":"commentary"}}

    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":1,"item":{"type":"message","id":"msg_phase_1","role":"assistant","status":"completed","content":[{"type":"output_text","text":"St. Augustine is the oldest major city.","phase":"commentary"}]}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":2,"item":{"type":"function_call","id":"fc_phase","call_id":"call_phase_weather","name":"get_weather","arguments":""}}

    event: response.function_call_arguments.delta
    data: {"type":"response.function_call_arguments.delta","output_index":2,"item_id":"fc_phase","delta":"{\\\"location\\\":"}

    event: response.function_call_arguments.delta
    data: {"type":"response.function_call_arguments.delta","output_index":2,"item_id":"fc_phase","delta":"\\\"St. Augustine, FL\\\"}"}

    event: response.function_call_arguments.done
    data: {"type":"response.function_call_arguments.done","output_index":2,"item_id":"fc_phase","name":"get_weather","arguments":"{\\\"location\\\":\\\"St. Augustine, FL\\\"}"}

    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":2,"item":{"type":"function_call","id":"fc_phase","call_id":"call_phase_weather","name":"get_weather","arguments":"{\\\"location\\\":\\\"St. Augustine, FL\\\"}","status":"completed"}}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_phase_1","model":"gpt-5.4","output":[]}}

    data: [DONE]
    """

    second_request = %{
      "model" => "gpt-5.4",
      "input" => [
        Responses.message(:user, prompt),
        %{
          "type" => "reasoning",
          "id" => "rs_phase",
          "summary" => [%{"type" => "summary_text", "text" => "Identified the city."}]
        },
        %{
          "type" => "message",
          "id" => "msg_phase_1",
          "role" => "assistant",
          "status" => "completed",
          "content" => [
            %{
              "type" => "output_text",
              "text" => "St. Augustine is the oldest major city.",
              "phase" => "commentary"
            }
          ]
        },
        %{
          "type" => "function_call",
          "id" => "fc_phase",
          "call_id" => "call_phase_weather",
          "name" => "get_weather",
          "arguments" => ~s({"location":"St. Augustine, FL"}),
          "status" => "completed"
        },
        Responses.function_call_output("call_phase_weather", "It's sunny.")
      ],
      "stream" => true,
      "tools" => tools,
      "reasoning" => reasoning,
      "text" => %{"verbosity" => "high"}
    }

    second_response = """
    event: response.created
    data: {"type":"response.created","response":{"id":"resp_phase_2","model":"gpt-5.4","output":[]}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_phase_2","role":"assistant","content":[]}}

    event: response.content_part.added
    data: {"type":"response.content_part.added","output_index":0,"item_id":"msg_phase_2","content_index":0,"part":{"type":"output_text","text":"","phase":"final_answer"}}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","output_index":0,"item_id":"msg_phase_2","content_index":0,"delta":"St. Augustine, FL is sunny."}

    event: response.output_text.done
    data: {"type":"response.output_text.done","output_index":0,"item_id":"msg_phase_2","content_index":0,"text":"St. Augustine, FL is sunny."}

    event: response.content_part.done
    data: {"type":"response.content_part.done","output_index":0,"item_id":"msg_phase_2","content_index":0,"part":{"type":"output_text","text":"St. Augustine, FL is sunny.","phase":"final_answer"}}

    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_phase_2","role":"assistant","status":"completed","content":[{"type":"output_text","text":"St. Augustine, FL is sunny.","phase":"final_answer"}]}}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_phase_2","model":"gpt-5.4","output":[]}}

    data: [DONE]
    """

    model =
      replay_model(
        write_gzip_cassette([
          {first_request, first_response, content_type: "text/event-stream"},
          {second_request, second_response, content_type: "text/event-stream"}
        ]),
        model: "gpt-5.4"
      )

    stream_opts = [
      tools: tools,
      reasoning: %{effort: :medium, summary: :auto},
      verbosity: :high
    ]

    assert {:ok, events} = ChatModel.stream_events(model, [Message.user(prompt)], stream_opts)

    assert Enum.any?(
             events,
             &match?(
               %{
                 "event" => "content-block-finish",
                 "content" => %{
                   "type" => "text",
                   "text" => "St. Augustine is the oldest major city.",
                   "phase" => "commentary"
                 }
               },
               &1
             )
           )

    assert {:ok, first} = ChatModel.stream_response(model, [Message.user(prompt)], stream_opts)

    assert [
             %{type: :reasoning},
             %{
               type: :text,
               text: "St. Augustine is the oldest major city.",
               phase: "commentary"
             },
             %{
               type: :tool_call,
               call_id: "call_phase_weather",
               name: "get_weather",
               arguments: ~s({"location":"St. Augustine, FL"})
             }
           ] = first.content

    assert [%ToolCall{call_id: "call_phase_weather"}] = first.tool_calls

    input_items =
      [Responses.message(:user, prompt)] ++
        Responses.output_items(first) ++
        [Responses.function_call_output(List.first(first.tool_calls), "It's sunny.")]

    assert {:ok, second} =
             ChatModel.stream_response(
               model,
               [],
               Keyword.put(stream_opts, :input_items, input_items)
             )

    assert [
             %{
               type: :text,
               text: "St. Augustine, FL is sunny.",
               phase: "final_answer"
             }
           ] = second.content
  end

  test "custom tool call output can drive a second Responses API turn" do
    custom_tool = ToolCalling.custom("execute_code", description: "Execute python code.")

    first_request = %{
      "model" => "gpt-5",
      "input" => [Responses.message(:user, "Use the tool to evaluate 3^3.")],
      "stream" => false,
      "tools" => [custom_tool]
    }

    first_response = %{
      "id" => "resp_custom_first",
      "output" => [
        %{"type" => "reasoning", "id" => "rs_1", "summary" => []},
        %{
          "type" => "custom_tool_call",
          "id" => "ctc_1",
          "status" => "completed",
          "call_id" => "call_custom",
          "input" => "print(3**3)",
          "name" => "execute_code"
        }
      ]
    }

    second_request = %{
      "model" => "gpt-5",
      "input" => [
        Responses.message(:user, "Use the tool to evaluate 3^3."),
        %{"type" => "reasoning", "id" => "rs_1", "summary" => []},
        %{
          "type" => "custom_tool_call",
          "id" => "ctc_1",
          "status" => "completed",
          "call_id" => "call_custom",
          "input" => "print(3**3)",
          "name" => "execute_code"
        },
        Responses.custom_tool_call_output("call_custom", "27")
      ],
      "stream" => false,
      "tools" => [custom_tool]
    }

    second_response = %{
      "id" => "resp_custom_second",
      "output" => [
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => "27"}]
        }
      ]
    }

    model =
      replay_model(
        write_gzip_cassette([
          {first_request, first_response},
          {second_request, second_response}
        ]),
        model: "gpt-5"
      )

    assert {:ok, first} =
             CoreChatModel.invoke(model, [Message.user("Use the tool to evaluate 3^3.")], tools: [custom_tool])

    assert %{"call_id" => "call_custom"} =
             Responses.first_output_item(first, "custom_tool_call")

    input_items =
      [Responses.message(:user, "Use the tool to evaluate 3^3.")] ++
        Responses.output_items(first) ++
        [Responses.custom_tool_call_output("call_custom", "27")]

    assert {:ok, second} =
             CoreChatModel.invoke(model, [], input_items: input_items, tools: [custom_tool])

    assert Message.text(second) == "27"
  end

  test "image generation output items can be fed into a follow-up turn" do
    image_tool =
      ToolCalling.image_generation(
        quality: "low",
        output_format: "jpeg",
        output_compression: 100,
        size: "1024x1024"
      )

    first_request = %{
      "model" => "gpt-4.1",
      "input" => [Responses.message(:user, "Draw a random short word in green font.")],
      "stream" => false,
      "tools" => [image_tool]
    }

    first_response = %{
      "id" => "resp_image_first",
      "output" => [
        %{
          "type" => "image_generation_call",
          "id" => "ig_1",
          "status" => "completed",
          "quality" => "low",
          "output_format" => "jpeg",
          "result" => "base64-image"
        },
        %{
          "type" => "message",
          "role" => "assistant",
          "id" => "msg_1",
          "content" => [
            %{
              "type" => "output_text",
              "text" => "Here's a random short word, \"SUN\", in green font.",
              "annotations" => []
            }
          ]
        }
      ]
    }

    second_request = %{
      "model" => "gpt-4.1",
      "input" => [
        Responses.message(:user, "Draw a random short word in green font."),
        %{
          "type" => "image_generation_call",
          "id" => "ig_1",
          "status" => "completed",
          "quality" => "low",
          "output_format" => "jpeg",
          "result" => "base64-image"
        },
        %{
          "type" => "message",
          "role" => "assistant",
          "id" => "msg_1",
          "content" => [
            %{
              "type" => "output_text",
              "text" => "Here's a random short word, \"SUN\", in green font.",
              "annotations" => []
            }
          ]
        },
        Responses.message(
          :user,
          "Now, change the font to blue. Keep the word and everything else the same."
        )
      ],
      "stream" => false,
      "tools" => [image_tool]
    }

    second_response = %{
      "output" => [
        %{"type" => "image_generation_call", "id" => "ig_2", "status" => "completed"},
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => "Updated the font to blue."}]
        }
      ]
    }

    model =
      replay_model(
        write_gzip_cassette([
          {first_request, first_response},
          {second_request, second_response}
        ]),
        model: "gpt-4.1"
      )

    assert {:ok, first} =
             CoreChatModel.invoke(
               model,
               [Message.user("Draw a random short word in green font.")],
               tools: [image_tool]
             )

    assert %{"type" => "image_generation_call", "result" => "base64-image"} =
             Responses.first_output_item(first, "image_generation_call")

    input_items =
      [Responses.message(:user, "Draw a random short word in green font.")] ++
        Responses.output_items(first) ++
        [
          Responses.message(
            :user,
            "Now, change the font to blue. Keep the word and everything else the same."
          )
        ]

    assert {:ok, second} =
             CoreChatModel.invoke(model, [], input_items: input_items, tools: [image_tool])

    assert Message.text(second) == "Updated the font to blue."
    assert %{"id" => "ig_2"} = Responses.first_output_item(second, "image_generation_call")
  end

  test "MCP ZDR follow-up preserves encrypted reasoning output items" do
    mcp_tool =
      ToolCalling.mcp("deepwiki", "https://mcp.deepwiki.com/mcp",
        allowed_tools: ["ask_question"],
        require_approval: "always"
      )

    prompt =
      "What transport protocols does the 2025-03-26 version of the MCP spec support?"

    first_request = %{
      "model" => "gpt-5-nano",
      "input" => [Responses.message(:user, prompt)],
      "stream" => false,
      "include" => ["reasoning.encrypted_content"],
      "store" => false,
      "tools" => [mcp_tool]
    }

    first_response = %{
      "id" => "resp_mcp_first",
      "output" => [
        %{
          "type" => "mcp_list_tools",
          "id" => "mcpl_1",
          "server_label" => "deepwiki",
          "tools" => [%{"name" => "ask_question"}]
        },
        %{
          "type" => "reasoning",
          "id" => "rs_1",
          "summary" => [],
          "encrypted_content" => "encrypted-reasoning"
        },
        %{
          "type" => "mcp_approval_request",
          "id" => "mcpr_1",
          "arguments" => ~s({"repoName":"modelcontextprotocol/modelcontextprotocol"}),
          "name" => "ask_question",
          "server_label" => "deepwiki"
        }
      ]
    }

    second_request = %{
      "model" => "gpt-5-nano",
      "input" => [
        Responses.message(:user, prompt),
        %{
          "type" => "mcp_list_tools",
          "id" => "mcpl_1",
          "server_label" => "deepwiki",
          "tools" => [%{"name" => "ask_question"}]
        },
        %{
          "type" => "reasoning",
          "id" => "rs_1",
          "summary" => [],
          "encrypted_content" => "encrypted-reasoning"
        },
        %{
          "type" => "mcp_approval_request",
          "id" => "mcpr_1",
          "arguments" => ~s({"repoName":"modelcontextprotocol/modelcontextprotocol"}),
          "name" => "ask_question",
          "server_label" => "deepwiki"
        },
        Responses.mcp_approval_response("mcpr_1")
      ],
      "stream" => false,
      "include" => ["reasoning.encrypted_content"],
      "store" => false,
      "tools" => [mcp_tool]
    }

    second_response = %{
      "output" => [
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => "It supports stdio and HTTP."}]
        }
      ]
    }

    model =
      replay_model(
        write_gzip_cassette([
          {first_request, first_response},
          {second_request, second_response}
        ]),
        model: "gpt-5-nano"
      )

    assert {:ok, first} =
             CoreChatModel.invoke(model, [Message.user(prompt)],
               tools: [mcp_tool],
               include: ["reasoning.encrypted_content"],
               extra_body: %{store: false}
             )

    assert %{"encrypted_content" => "encrypted-reasoning"} =
             Responses.first_output_item(first, "reasoning")

    input_items =
      [Responses.message(:user, prompt)] ++
        Responses.output_items(first) ++
        [
          Responses.mcp_approval_response(Responses.first_output_item(first, "mcp_approval_request"))
        ]

    assert {:ok, second} =
             CoreChatModel.invoke(model, [],
               input_items: input_items,
               tools: [mcp_tool],
               include: ["reasoning.encrypted_content"],
               extra_body: %{store: false}
             )

    assert Message.text(second) == "It supports stdio and HTTP."
  end

  defp replay_model(cassette_path, opts \\ []) do
    struct(
      ChatModel,
      [
        api_key: "sk-replay-test",
        transport: BeamWeaver.Transport.Replay,
        transport_opts: [cassette_path: cassette_path]
      ] ++ opts
    )
  end

  defp write_gzip_cassette(request_body, response_body) do
    write_gzip_cassette([{request_body, response_body}])
  end

  defp write_gzip_cassette(interactions) when is_list(interactions) do
    path =
      Path.join([
        System.tmp_dir!(),
        "beam_weaver_openai_builtin_#{System.unique_integer([:positive])}.yaml.gz"
      ])

    File.write!(path, :zlib.gzip(cassette_yaml(interactions)))
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp cassette_yaml(interactions) do
    requests =
      Enum.map_join(interactions, "\n", fn interaction ->
        {request_body, _response_body, _opts} = normalize_interaction(interaction)

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
      Enum.map_join(interactions, "\n", fn interaction ->
        {_request_body, response_body, opts} = normalize_interaction(interaction)
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

  defp normalize_interaction({request_body, response_body}) do
    {request_body, response_body, []}
  end

  defp normalize_interaction({request_body, response_body, opts}) do
    {request_body, response_body, opts}
  end

  defp response_body(response_body) when is_binary(response_body), do: response_body
  defp response_body(response_body), do: BeamWeaver.JSON.encode!(response_body)
end
