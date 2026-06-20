defmodule BeamWeaver.Provider.ChatRuntimeTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Provider.ChatRuntime
  alias BeamWeaver.Provider.ChatRuntime.Adapter

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
end
