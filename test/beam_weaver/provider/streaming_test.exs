defmodule BeamWeaver.Provider.StreamingTest do
  use ExUnit.Case, async: true

  # Some streams report an error no provider documents, which logs a warning
  # (see `BeamWeaver.Provider.StreamFailureTest`).
  @moduletag :capture_log

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Provider.ResponseDecoder
  alias BeamWeaver.Provider.Streaming
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.Transport.Request
  alias BeamWeaver.Transport.Response

  # Hands the scripted chunks to the reducer one at a time, then closes the
  # 200 response.
  defmodule Chunks do
    @behaviour BeamWeaver.Transport

    @impl true
    def request(_request, _opts), do: raise("unexpected non-streaming request")

    @impl true
    def stream_reduce(_request, opts, acc, reducer) do
      acc = Enum.reduce(Keyword.fetch!(opts, :chunks), acc, &reducer.(&2, &1))
      {:ok, Response.new(status: 200, headers: [{"request-id", "req_1"}]), acc}
    end
  end

  @request Request.new(method: :post, url: "https://api.example.test/v1/messages")
  @overloaded %{"type" => "error", "error" => %{"type" => "overloaded_error", "message" => "Overloaded"}}

  describe "live_sse/6" do
    test "a stream that reports an error after its 200 response ends with that error, not the reply" do
      error_event = event(@overloaded)
      {first, second} = String.split_at(error_event, 12)

      assert [
               "hel",
               "lo",
               %Events.Error{error: %Error{type: :server_error, message: "Overloaded", details: details}}
             ] = live([event(delta("hel")), event(delta("lo")) <> first, second, event(delta("ignored"))])

      assert details.status == 529
      assert details.error_type == "overloaded_error"
      assert details.retryable
      assert details.request_id == "req_1"
      refute_received :finalized
    end

    test "events after the error in the same chunk are dropped" do
      assert ["hel", %Events.Error{error: %Error{details: %{status: 529}}}] =
               live([event(delta("hel")) <> event(@overloaded) <> event(delta("lo"))])
    end

    test "an error in the last event, without the blank line that ends it, fails the stream" do
      last = String.trim_trailing(event(@overloaded))

      assert ["hel", %Events.Error{error: %Error{details: %{status: 529}}}] = live([event(delta("hel")), last])
      refute_received :finalized
    end

    test "a stream without an error still ends with its finalizer's items" do
      assert ["hel", "lo", :final] = live([event(delta("hel")), event(delta("lo"))])
      assert_received :finalized
    end

    for {name, data, status, message} <- [
          {"Anthropic rate_limit_error",
           %{"type" => "error", "error" => %{"type" => "rate_limit_error", "message" => "Slow down"}}, 429,
           "Slow down"},
          {"Anthropic invalid_request_error",
           %{"type" => "error", "error" => %{"type" => "invalid_request_error", "message" => "Bad"}}, 400, "Bad"},
          {"Anthropic error type it doesn't know",
           %{"type" => "error", "error" => %{"type" => "brand_new_error", "message" => "New"}}, 500, "New"},
          {"OpenAI Responses error event",
           %{"type" => "error", "code" => "server_error", "message" => "Boom", "param" => nil, "sequence_number" => 3},
           500, "Boom"},
          {"Chat Completions error chunk",
           %{"error" => %{"message" => "Server error", "type" => "server_error", "code" => nil}}, 500, "Server error"},
          {"Gemini error chunk", %{"error" => %{"code" => 503, "message" => "Try again", "status" => "UNAVAILABLE"}},
           503, "Try again"}
        ] do
      test "#{name} fails the stream with the status of its error" do
        assert ["hel", %Events.Error{error: %Error{} = error}] =
                 live([event(delta("hel")), event(unquote(Macro.escape(data)))])

        assert error.details.status == unquote(status)
        assert error.message == unquote(message)
        assert error.details.retryable == BeamWeaver.RetryPredicates.transient_status?(unquote(status))
      end
    end

    test "an `error` event whose data has another type, as a gateway may send it, fails the stream" do
      error_event =
        "event: error\ndata: #{BeamWeaver.JSON.encode!(%{"type" => "overloaded_error", "message" => "Busy"})}\n\n"

      assert ["hel", %Events.Error{error: %Error{message: "Busy", details: %{status: 529}}}] =
               live([event(delta("hel")), error_event])
    end

    test "a failed Responses API response fails the stream with the status of its error" do
      failed = %{
        "type" => "response.failed",
        "sequence_number" => 7,
        "response" => %{
          "id" => "resp_1",
          "status" => "failed",
          "error" => %{"code" => "rate_limit_exceeded", "message" => "Rate limit reached"},
          "usage" => %{"input_tokens" => 12, "output_tokens" => 3}
        }
      }

      assert ["hel", %Events.Error{error: %Error{type: :rate_limit, message: "Rate limit reached"} = error}] =
               live([event(delta("hel")), event(failed), event(delta("ignored"))])

      assert error.details.status == 429
      assert error.details.code == "rate_limit_exceeded"
      assert error.details.retryable
      assert error.details.body["response"]["usage"] == %{"input_tokens" => 12, "output_tokens" => 3}
      refute_received :finalized
    end

    test "a failed response without an error object still fails the stream" do
      failed = %{"type" => "response.failed", "response" => %{"id" => "resp_1", "status" => "failed"}}

      assert [%Events.Error{error: %Error{message: "Model response failed", details: %{status: 500}}}] =
               live([event(failed)])
    end

    test "events that only mention an error, and an incomplete response, are not failures" do
      events = [
        %{"choices" => [%{"index" => 0, "delta" => %{"content" => "hel"}}], "error" => nil},
        %{"type" => "response.created", "response" => %{"status" => "in_progress", "error" => nil}},
        %{
          "type" => "response.incomplete",
          "response" => %{
            "status" => "incomplete",
            "error" => nil,
            "incomplete_details" => %{"reason" => "content_filter"}
          }
        }
      ]

      parser = fn events -> Enum.map(events, & &1["data"]) end
      assert live(Enum.map(events, &event/1), parser) == events ++ [:final]
    end

    # Z.ai's and DeepSeek's finish reasons for a reply they couldn't finish.
    for {reason, status} <- [
          {"network_error", 500},
          {"sensitive", 400},
          {"insufficient_system_resource", 503},
          {"aborted", 500}
        ] do
      test "a chunk with the finish reason #{reason} fails the stream with status #{status}" do
        last = %{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => unquote(reason)}]}

        assert ["hel", %Events.Error{error: %Error{} = error}] = live([event(delta("hel")), event(last)])
        assert error.details.status == unquote(status)
        assert error.details.code == unquote(reason)
        assert error.message =~ "(finish_reason: #{unquote(reason)})"
        refute_received :finalized
      end
    end

    test "chunks that end the reply with another finish reason are not failures" do
      events =
        for reason <- ["stop", "length", "tool_calls", "content_filter", "model_context_window_exceeded"],
            do: %{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => reason}]}

      parser = fn events -> Enum.map(events, & &1["data"]) end
      assert live(Enum.map(events, &event/1), parser) == events ++ [:final]
    end
  end

  describe "StreamFailure.status/1" do
    # The status each provider documents for the error, which its decoder then
    # classifies as it would the same error without streaming.
    for {name, error, status} <- [
          {"an OpenAI rate limit", %{"code" => "rate_limit_exceeded", "type" => "requests"}, 429},
          {"an exhausted OpenAI quota", %{"code" => "insufficient_quota", "type" => "insufficient_quota"}, 429},
          {"an OpenAI context overflow", %{"code" => "context_length_exceeded", "type" => "invalid_request_error"},
           400},
          {"a prompt OpenAI rejects", %{"code" => "invalid_prompt"}, 400},
          {"an OpenAI image the policy rejects", %{"code" => "image_content_policy_violation"}, 400},
          {"an overloaded OpenAI server", %{"code" => "server_is_overloaded", "type" => "service_unavailable_error"},
           503},
          {"a Kimi content filter", %{"type" => "content_filter"}, 400},
          {"an exhausted Kimi quota", %{"type" => "exceeded_current_quota_error"}, 429},
          {"an overloaded Kimi engine", %{"type" => "engine_overloaded_error"}, 429},
          {"a Z.ai content filter", %{"code" => "1301"}, 400},
          {"a Z.ai content filter with a numeric code", %{"code" => 1301}, 400},
          {"Z.ai's insufficient balance", %{"code" => "1113"}, 429},
          {"Z.ai's prompt too long", %{"code" => "1261"}, 400},
          {"a Z.ai rate limit", %{"code" => "1302"}, 429},
          {"a Z.ai network error", %{"code" => "1234"}, 500},
          {"a Gemini error, by its code", %{"code" => 503, "status" => "UNAVAILABLE"}, 503},
          {"a Gemini error, by its status name", %{"status" => "RESOURCE_EXHAUSTED"}, 429},
          {"a code that is an HTTP status", %{"code" => "502"}, 502},
          {"an Anthropic error type", %{"type" => "billing_error"}, 402},
          {"an error no provider documents", %{"code" => "brand_new", "type" => "brand_new_error"}, 500},
          {"an error without a name", %{"message" => "Boom"}, 500}
        ] do
      test "#{name} has status #{status}" do
        assert BeamWeaver.Provider.StreamFailure.status(unquote(Macro.escape(error))) == unquote(status)
      end
    end
  end

  describe "collect/4" do
    test "a collected stream that reports an error decodes to that error" do
      body = event(delta("hel")) <> event(@overloaded)

      assert {:error, %Error{type: :server_error, message: "Overloaded", details: %{status: 529, request_id: "req_1"}}} =
               Streaming.collect(Chunks, @request, [chunks: [body]], &decode_error/1)
    end

    test "a collected stream whose finish reason reports a failure decodes to that error" do
      body = event(delta("hel")) <> event(%{"choices" => [%{"index" => 0, "finish_reason" => "network_error"}]})

      assert {:error, %Error{type: :server_error, details: %{status: 500, code: "network_error", request_id: "req_1"}}} =
               Streaming.collect(Chunks, @request, [chunks: [body]], &decode_error/1)
    end

    test "a collected stream without an error decodes its body" do
      body = event(delta("hel"))

      assert {:ok, %Response{status: 200, body: ^body}} =
               Streaming.collect(Chunks, @request, [chunks: [body]], &decode_error/1)
    end
  end

  defp live(chunks, parser \\ &text_deltas/1) do
    test = self()

    finalizer = fn _state, _response ->
      send(test, :finalized)
      {:ok, [:final]}
    end

    Chunks
    |> Streaming.live_sse(@request, [chunks: chunks], [parser_finalizer: finalizer], parser, &decode_error/1)
    |> Enum.to_list()
  end

  defp text_deltas(events), do: for(%{"data" => %{"delta" => %{"text" => text}}} <- events, do: text)

  defp decode_error(result),
    do: ResponseDecoder.decode(result, [provider: :anthropic, request_id_header: "request-id"], &{:ok, &1})

  defp delta(text),
    do: %{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "text_delta", "text" => text}}

  defp event(%{"type" => type} = data), do: "event: #{type}\ndata: #{BeamWeaver.JSON.encode!(data)}\n\n"
  defp event(data), do: "data: #{BeamWeaver.JSON.encode!(data)}\n\n"
end
