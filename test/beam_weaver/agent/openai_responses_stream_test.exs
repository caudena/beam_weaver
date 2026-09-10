defmodule BeamWeaver.Agent.OpenAIResponsesStreamTest do
  use ExUnit.Case, async: false

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.OpenAI.ChatModel
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.Transport.ReqFinch

  @provider_error "Expected an ID that begins with 'fc'"

  for store <- [nil, false] do
    @store store
    test "typed streaming agent performs model -> local tool -> model over HTTP with store=#{inspect(store)}" do
      parent = self()
      first = first_events()
      second = second_events()

      {url, server} =
        start_server(2, fn socket, index, request ->
          send(parent, {:wire_request, index, request})

          if index == 1 do
            send_sse(socket, first, true)
          else
            item = Enum.find(request["input"], &(&1["type"] == "function_call"))

            if item["id"] == if(@store == false, do: nil, else: "fc_probe") do
              send_sse(socket, second)
            else
              send_http(socket, "400 Bad Request", "application/json", error_json())
            end
          end
        end)

      tool =
        Tool.from_function!(
          name: "probe",
          description: "Return a local test value",
          input_schema: %{
            "type" => "object",
            "properties" => %{"value" => %{"type" => "string"}},
            "required" => ["value"]
          },
          handler: fn args, _opts ->
            send(parent, {:executed, args})
            "pong"
          end
        )

      model = %ChatModel{
        model: "gpt-5.4-mini",
        endpoint: url,
        api_key: "local-fixture-only",
        store: @store,
        transport: ReqFinch,
        timeout: 5_000
      }

      {:ok, agent} = BeamWeaver.Agent.build(model: model, tools: [tool], model_opts: [stream: true])

      {:ok, stream} =
        BeamWeaver.Agent.stream_events(agent, %{messages: [Message.user("Use probe, then answer.")]},
          live: true,
          stream_mode: :events
        )

      events =
        Enum.map(stream, fn %Envelope{event: event} ->
          if match?(%Events.Token{text: "Checking."}, event), do: send(server, :continue)
          event
        end)

      assert_receive {:executed, %{"value" => "ping"}}, 1_000
      assert_receive {:wire_request, 1, %{"stream" => true}}, 1_000
      assert_receive {:wire_request, 2, request}, 1_000
      refute_received {:executed, _args}
      item = Enum.find(request["input"], &(&1["type"] == "function_call"))
      reasoning = Enum.find(request["input"], &(&1["type"] == "reasoning"))
      output = Enum.find(request["input"], &(&1["type"] == "function_call_output"))
      assert output["call_id"] == "call_probe"
      assert output["output"] == "pong"
      assert item["call_id"] == "call_probe"
      assert BeamWeaver.JSON.decode!(item["arguments"]) == %{"value" => "ping"}

      messages =
        Enum.flat_map(events, fn
          %Events.GraphUpdate{update: %{"model" => %{messages: messages}}} -> messages
          _ -> []
        end)

      errors =
        Enum.flat_map(events, fn
          %Events.Error{error: error} -> [error]
          _ -> []
        end)

      tokens =
        Enum.flat_map(events, fn
          %Events.Token{text: text} -> [text]
          _ -> []
        end)

      assert item["id"] == if(@store == false, do: nil, else: "fc_probe")
      assert reasoning["id"] == if(@store == false, do: nil, else: "rs_probe")
      assert reasoning["encrypted_content"] == "encrypted_fixture"
      assert Enum.map(messages, &Message.text/1) == ["Checking.", "Done."]
      assert hd(messages).response_metadata[:id] == "resp_probe_1"
      assert hd(messages).response_metadata[:service_tier] == "default"
      assert hd(messages).response_metadata[:provider_metadata] == %{"fixture" => "yes"}
      assert hd(messages).usage_metadata.total_tokens == 12
      assert [%{id: "call_probe", call_id: "call_probe", provider_id: "fc_probe"}] = hd(messages).tool_calls
      assert errors == []
      assert tokens == ["Checking.", "Done."]

      assistant_messages =
        Enum.flat_map(events, fn
          %Events.Message{message: %Message{role: :assistant} = message} -> [message]
          _ -> []
        end)

      assert Enum.map(assistant_messages, & &1.id) == ["resp_probe_1", "resp_probe_2"]
      assert Enum.map(assistant_messages, &Message.text/1) == ["Checking.", "Done."]
    end
  end

  test "provider terminal snapshot is emitted before Done without duplicate token events" do
    events = first_events() |> Enum.map(&%{"data" => &1}) |> BeamWeaver.OpenAI.Streaming.typed_events()
    events = Enum.map(events, & &1.event)

    assert Enum.flat_map(events, fn
             %Events.Token{text: text} -> [text]
             _ -> []
           end) == ["Checking."]

    assert [%Events.Message{message: message}, %Events.Done{}] = Enum.take(events, -2)
    assert Message.text(message) == "Checking."
    assert Enum.count(events, &match?(%Events.Message{}, &1)) == 1
  end

  test "typed streaming exposes JSON HTTP 400 as the provider error" do
    {url, _server} =
      start_server(1, fn socket, _, _ ->
        send_http(socket, "400 Bad Request", "application/json", error_json())
      end)

    model = %ChatModel{model: "gpt-5.4-mini", endpoint: url, api_key: "local-fixture-only", transport: ReqFinch}
    assert {:ok, stream} = ChatModel.stream_typed_events(model, [Message.user("hello")])
    events = Enum.to_list(stream)

    assert [%Envelope{event: %Events.Error{error: error}}] =
             Enum.filter(events, &match?(%Envelope{event: %Events.Error{}}, &1))

    refute Enum.any?(events, &match?(%Envelope{event: %Events.Message{}}, &1))
    assert error.type == :http_error
    assert error.message == @provider_error
    assert error.details.status == 400
    assert error.details.request_id == "req_fixture"
    assert error.details.param == "input[1].id"
  end

  defp first_events do
    reasoning = %{
      "type" => "reasoning",
      "id" => "rs_probe",
      "summary" => [%{"type" => "summary_text", "text" => "Need a tool"}],
      "encrypted_content" => "encrypted_fixture"
    }

    message = %{
      "type" => "message",
      "id" => "msg_probe_1",
      "role" => "assistant",
      "status" => "completed",
      "content" => [%{"type" => "output_text", "text" => "Checking."}]
    }

    call = %{
      "type" => "function_call",
      "id" => "fc_probe",
      "call_id" => "call_probe",
      "name" => "probe",
      "arguments" => ~s({"value":"ping"}),
      "status" => "completed"
    }

    [
      %{
        "type" => "response.created",
        "response" => %{"id" => "resp_probe_1", "output" => [], "status" => "in_progress"}
      },
      %{"type" => "response.output_item.added", "output_index" => 0, "item" => Map.put(reasoning, "summary", [])},
      %{
        "type" => "response.reasoning_summary_text.delta",
        "item_id" => "rs_probe",
        "output_index" => 0,
        "delta" => "Need a tool"
      },
      %{"type" => "response.output_item.done", "output_index" => 0, "item" => reasoning},
      %{"type" => "response.output_item.added", "output_index" => 1, "item" => Map.put(message, "content", [])},
      %{
        "type" => "response.output_text.delta",
        "item_id" => "msg_probe_1",
        "output_index" => 1,
        "content_index" => 0,
        "delta" => "Checking."
      },
      %{"type" => "response.output_item.done", "output_index" => 1, "item" => message},
      %{"type" => "response.output_item.added", "output_index" => 2, "item" => Map.put(call, "arguments", "")},
      %{
        "type" => "response.function_call_arguments.delta",
        "item_id" => "fc_probe",
        "output_index" => 2,
        "delta" => ~s({"value":)
      },
      %{
        "type" => "response.function_call_arguments.delta",
        "item_id" => "fc_probe",
        "output_index" => 2,
        "delta" => ~s("ping"})
      },
      %{"type" => "response.output_item.done", "output_index" => 2, "item" => call},
      %{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_probe_1",
          "model" => "gpt-5.4-mini",
          "status" => "completed",
          "output" => [reasoning, message, call],
          "service_tier" => "default",
          "metadata" => %{"fixture" => "yes"},
          "usage" => %{"input_tokens" => 8, "output_tokens" => 4, "total_tokens" => 12}
        }
      }
    ]
  end

  defp second_events do
    message = %{
      "type" => "message",
      "id" => "msg_probe_2",
      "role" => "assistant",
      "status" => "completed",
      "content" => [%{"type" => "output_text", "text" => "Done."}]
    }

    [
      %{
        "type" => "response.output_text.delta",
        "item_id" => "msg_probe_2",
        "output_index" => 0,
        "content_index" => 0,
        "delta" => "Done."
      },
      %{"type" => "response.output_item.done", "output_index" => 0, "item" => message},
      %{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_probe_2",
          "model" => "gpt-5.4-mini",
          "status" => "completed",
          "output" => [message]
        }
      }
    ]
  end

  defp error_json do
    BeamWeaver.JSON.encode!(%{
      "error" => %{
        "message" => @provider_error,
        "type" => "invalid_request_error",
        "param" => "input[1].id",
        "code" => "invalid_value"
      }
    })
  end

  defp start_server(count, handler) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)

    task =
      Task.async(fn ->
        for index <- 1..count do
          {:ok, socket} = :gen_tcp.accept(listener, 5_000)
          request = read_request(socket, "")
          handler.(socket, index, request)
          :gen_tcp.close(socket)
        end

        :gen_tcp.close(listener)
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(task.pid), do: Process.exit(task.pid, :kill)
    end)

    {"http://127.0.0.1:#{port}/v1/responses", task.pid}
  end

  defp read_request(socket, buffer) do
    case String.split(buffer, "\r\n\r\n", parts: 2) do
      [headers, body] ->
        [_, length] = Regex.run(~r/content-length: (\d+)/i, headers)
        size = String.to_integer(length)

        if byte_size(body) >= size do
          BeamWeaver.JSON.decode!(binary_part(body, 0, size))
        else
          {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
          read_request(socket, buffer <> data)
        end

      _ ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
        read_request(socket, buffer <> data)
    end
  end

  defp send_sse(socket, events, wait_for_token? \\ false) do
    chunks = Enum.map(events, fn event -> "event: #{event["type"]}\ndata: #{BeamWeaver.JSON.encode!(event)}\n\n" end)
    bytes = Enum.reduce(chunks, 0, &(byte_size(&1) + &2))

    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncontent-length: #{bytes}\r\nconnection: close\r\n\r\n"
      )

    Enum.zip(events, chunks)
    |> Enum.each(fn {event, chunk} ->
      if wait_for_token? and event["type"] == "response.completed" do
        # The consumer must receive the text delta before the terminal response
        # is sent; buffering the entire response would deadlock this handshake.
        receive do
          :continue -> :ok
        after
          2_000 -> raise "streamed token was not delivered before the terminal response"
        end
      end

      :ok = :gen_tcp.send(socket, chunk)
    end)
  end

  defp send_http(socket, status, content_type, body) do
    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 #{status}\r\ncontent-type: #{content_type}\r\nx-request-id: req_fixture\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
      )
  end
end
