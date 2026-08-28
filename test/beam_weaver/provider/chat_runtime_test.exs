defmodule BeamWeaver.Provider.ChatRuntimeTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Provider.ChatRuntime
  alias BeamWeaver.Provider.ChatRuntime.Adapter
  alias BeamWeaver.Core.Message

  defp base_adapter(overrides) do
    defaults = %{
      request: fn _model, _messages, _opts -> {:ok, %{}} end,
      invoke: fn _model, _body, _opts -> {:ok, %{}} end,
      stream: fn _model, _body, _opts -> {:ok, []} end,
      stream_response: fn _model, _body, _opts -> {:ok, %{}} end,
      decode: fn _response, _opts -> {:ok, %{}} end,
      source: :model
    }

    struct!(Adapter, Map.merge(defaults, overrides))
  end

  describe "stream_events/4 with nil metadata builder" do
    test "defaults to empty metadata instead of raising FunctionClauseError" do
      adapter =
        base_adapter(%{
          stream_events: fn _model, _body, _opts -> {:ok, []} end,
          metadata: nil
        })

      assert {:ok, _stream} = ChatRuntime.stream_events(%{}, [], [], adapter)
    end

    test "uses the metadata builder when one is provided" do
      adapter =
        base_adapter(%{
          stream_events: fn _model, _body, _opts -> {:ok, []} end,
          metadata: fn _model, _body, _opts -> %{provider: :test} end
        })

      assert {:ok, _stream} = ChatRuntime.stream_events(%{}, [], [], adapter)
    end
  end

  describe "stream_exact_events/4" do
    test "dispatches the supplied bytes without rebuilding the request" do
      parent = self()
      exact_body = ~s({"messages":[{"role":"user","content":"exact"}],"stream":true})

      adapter =
        base_adapter(%{
          request: fn _model, _messages, _opts ->
            flunk("exact dispatch must not invoke the request renderer")
          end,
          exact_stream_events: fn _model, body, opts ->
            send(parent, {:dispatched, body, opts})
            {:ok, []}
          end
        })

      opts = [exact_request_metadata: %{request_hash: "hash"}]

      assert {:ok, _stream} = ChatRuntime.stream_exact_events(%{}, exact_body, opts, adapter)
      assert_received {:dispatched, ^exact_body, ^opts}
    end

    test "does not send exact bytes through a map-only ordinary stream function" do
      adapter =
        base_adapter(%{
          stream_events: fn _model, body, _opts when is_map(body) -> {:ok, []} end
        })

      assert {:error, %BeamWeaver.Core.Error{type: :unsupported_feature}} =
               ChatRuntime.stream_exact_events(%{}, ~s({"stream":true}), [], adapter)
    end
  end

  describe "invoke/4 response parsing" do
    test "passes the model to three-arity provider parsers" do
      parent = self()
      model = %{include_response_headers: false, id: :configured_model}
      message = Message.assistant("ok")

      adapter =
        base_adapter(%{
          decode: fn _response, _opts -> {:ok, message} end,
          parse: fn parsed_model, parsed_message, opts ->
            send(parent, {:parsed, parsed_model, parsed_message, opts})
            {:ok, parsed_message}
          end
        })

      assert {:ok, ^message} = ChatRuntime.invoke(model, [], [response_format: %{type: :json}], adapter)

      assert_received {:parsed, ^model, ^message, [include_response_headers: false, response_format: %{type: :json}]}
    end

    test "keeps two-arity provider parsers backward compatible" do
      parent = self()
      model = %{include_response_headers: false}
      message = Message.assistant("ok")

      adapter =
        base_adapter(%{
          decode: fn _response, _opts -> {:ok, message} end,
          parse: fn parsed_message, opts ->
            send(parent, {:parsed, parsed_message, opts})
            {:ok, parsed_message}
          end
        })

      assert {:ok, ^message} = ChatRuntime.invoke(model, [], [], adapter)
      assert_received {:parsed, ^message, [include_response_headers: false]}
    end
  end
end
