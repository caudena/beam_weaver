defmodule BeamWeaver.Agent.OverflowRecoveryTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.Middleware.OverflowRecovery
  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message

  # Rejects any request with a message over 10,000 characters, the way a
  # provider rejects a request that is too long for the model.
  defmodule SmallWindowModel do
    @behaviour BeamWeaver.Core.ChatModel

    defstruct []

    @impl true
    def invoke(%__MODULE__{}, messages, opts) do
      send(opts[:context].parent, {:model_call, messages})

      cond do
        Enum.any?(messages, &(String.length(Message.text(&1)) > 10_000)) ->
          {:error, Error.new(:context_overflow, "prompt is too long")}

        match?(%Message{role: :user}, List.last(messages)) and length(messages) == 1 ->
          {:ok, Message.assistant("", tool_calls: [%{id: "call_1", name: "order_history", args: %{}}])}

        true ->
          {:ok, Message.assistant("Ada has 5,000 orders.")}
      end
    end
  end

  defmodule OrderHistory do
    use BeamWeaver.Tool

    name "order_history"
    description "Export all orders of a customer as CSV."

    schema do
    end

    @impl true
    def invoke(_tool, _input, _opts) do
      rows = for n <- 1..5_000, do: "A-#{1000 + n},shipped,2026-05-04\n"
      {:ok, IO.iodata_to_binary(["order_id,status,shipped_on\n" | rows])}
    end
  end

  defmodule SupportAgent do
    use BeamWeaver.Agent

    model %SmallWindowModel{}
    tools [OrderHistory]
    overflow_recovery true
  end

  defp invoke(input, opts), do: SupportAgent.invoke(input, Keyword.put(opts, :context, %{parent: self()}))

  test "the clipped result is saved in the thread, so the next call doesn't overflow" do
    opts = [checkpointer: Checkpoint.ETS.new(), config: %{"configurable" => %{"thread_id" => "overflow"}}]

    assert {:ok, first} = invoke(%{messages: ["How many orders does Ada have?"]}, opts)
    assert List.last(first.messages) |> Message.text() == "Ada has 5,000 orders."

    tool_message = Enum.find(first.messages, &(&1.role == :tool))
    assert Message.text(tool_message) =~ "saved in the filesystem at this path: /large_tool_results/call_1"
    assert first.files["/large_tool_results/call_1"].content =~ "A-6000,shipped"

    flush_model_calls()

    assert {:ok, second} = invoke(%{messages: ["Thanks!"]}, opts)
    assert List.last(second.messages) |> Message.text() == "Ada has 5,000 orders."
    assert [_one_call] = flush_model_calls()
  end

  test "keep defaults to a 5,000-token threshold and rejects a message count" do
    assert %OverflowRecovery{keep: {:tokens, 5_000}} = OverflowRecovery.new()

    assert_raise ArgumentError, ~r/keep must be \{:tokens, n\} or \{:fraction, f\}/, fn ->
      OverflowRecovery.new(keep: {:messages, 8})
    end
  end

  defp flush_model_calls do
    receive do
      {:model_call, messages} -> [messages | flush_model_calls()]
    after
      0 -> []
    end
  end
end
