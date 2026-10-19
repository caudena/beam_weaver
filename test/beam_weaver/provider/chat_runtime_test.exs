defmodule BeamWeaver.Provider.ChatRuntimeTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Message

  defmodule FakeModel do
    defstruct model: "fake", profile: nil, include_response_headers: false, parent: nil, metadata: nil
    @type t :: %__MODULE__{}

    use BeamWeaver.Provider.ChatModel, stream_source: :fake

    @impl true
    def request_body(%__MODULE__{}, _messages, opts), do: {:ok, %{"stream" => Keyword.fetch!(opts, :stream)}}

    @impl true
    def send_request(call, %__MODULE__{parent: parent}, body, opts) do
      send(parent, {:sent, call, body, opts})
      {:ok, if(call == :invoke, do: %{}, else: [])}
    end

    @impl true
    def decode_response(_response, _opts), do: {:ok, Message.assistant("ok")}

    @impl true
    def parse_response(%__MODULE__{parent: parent} = model, message, opts) do
      send(parent, {:parsed, model, message, opts})
      {:ok, message}
    end

    @impl true
    def stream_metadata(%__MODULE__{metadata: metadata}, _body, _opts), do: metadata || %{}
  end

  defmodule ExactModel do
    defstruct model: "exact", profile: nil, include_response_headers: false, parent: nil
    @type t :: %__MODULE__{}

    use BeamWeaver.Provider.ChatModel, stream_source: :exact, exact_stream_events: true

    @impl true
    def request_body(_model, _messages, _opts), do: flunk("exact dispatch must not invoke the request renderer")

    @impl true
    def send_request(:exact_stream_events, %__MODULE__{parent: parent}, body, opts) do
      send(parent, {:dispatched, body, opts})
      {:ok, []}
    end

    @impl true
    def decode_response(response, _opts), do: {:ok, response}
  end

  describe "stream_typed_events/3" do
    test "sends a streaming body through send_request(:stream_events, ...)" do
      model = %FakeModel{parent: self(), metadata: %{provider: :test}}

      assert {:ok, stream} = FakeModel.stream_typed_events(model, [], [])
      Stream.run(stream)
      assert_received {:sent, :stream_events, %{"stream" => true}, []}
    end

    test "has the provider's events only, without the start and stop of the process that reads them" do
      model = %FakeModel{parent: self(), metadata: %{provider: :test}}

      assert {:ok, stream} = FakeModel.stream_typed_events(model, [], [])
      assert Enum.to_list(stream) == []
    end
  end

  describe "stream_exact_typed_events/3" do
    test "dispatches the supplied bytes without rebuilding the request" do
      exact_body = ~s({"messages":[{"role":"user","content":"exact"}],"stream":true})
      opts = [exact_request_metadata: %{request_hash: "hash"}]

      assert {:ok, _stream} = ExactModel.stream_exact_typed_events(%ExactModel{parent: self()}, exact_body, opts)
      assert_received {:dispatched, ^exact_body, ^opts}
    end

    test "is unsupported unless the model opts in" do
      assert {:error, %BeamWeaver.Core.Error{type: :unsupported_feature}} =
               FakeModel.stream_exact_typed_events(%FakeModel{parent: self()}, ~s({"stream":true}), [])

      refute_received {:sent, _call, _body, _opts}
    end
  end

  describe "invoke/3" do
    test "passes the model and the call options to parse_response/3" do
      model = %FakeModel{parent: self()}

      assert {:ok, %Message{}} = FakeModel.invoke(model, [], response_format: %{type: :json})

      assert_received {:sent, :invoke, %{"stream" => false},
                       [include_response_headers: false, response_format: %{type: :json}]}

      assert_received {:parsed, ^model, %Message{}, [include_response_headers: false, response_format: %{type: :json}]}
    end
  end
end
