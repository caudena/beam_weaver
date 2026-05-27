defmodule BeamWeaver.TestSupport.Conformance.ChatHistoryCase do
  @moduledoc """
  Shared ExUnit checks for `BeamWeaver.Core.ChatHistory` sessions.
  """

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use ExUnit.Case, async: true

      alias BeamWeaver.Core.ChatHistory
      alias BeamWeaver.Core.Message

      @beamweaver_session Keyword.fetch!(opts, :session)

      test "chat history appends, reads, and clears messages" do
        session = beamweaver_standard_value(@beamweaver_session)

        assert {:ok, []} = ChatHistory.get_messages(session)
        assert :ok = ChatHistory.add_messages(session, [Message.user("hello")])
        assert {:ok, [%Message{content: "hello"}]} = ChatHistory.get_messages(session)
        assert :ok = ChatHistory.clear(session)
        assert {:ok, []} = ChatHistory.get_messages(session)
      end

      defp beamweaver_standard_value(value) when is_function(value, 0), do: value.()
      defp beamweaver_standard_value(value), do: value
    end
  end
end
