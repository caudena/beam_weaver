defmodule BeamWeaver.TestSupport.Conformance.AgentCase do
  @moduledoc """
  Shared ExUnit checks for user-defined `BeamWeaver.Agent` modules.

  This keeps standard-test style coverage idiomatic to ExUnit: test modules opt
  into capability checks rather than inheriting Python test classes.
  """

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use ExUnit.Case, async: true

      alias BeamWeaver.Agent
      alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
      alias BeamWeaver.Core.Message
      alias BeamWeaver.Stream.Envelope

      @beamweaver_agent Keyword.fetch!(opts, :agent)
      @beamweaver_input Keyword.get(opts, :input, %{messages: [Message.user("hello")]})
      @beamweaver_context Keyword.get(opts, :context, %{})
      @beamweaver_capabilities Keyword.get(opts, :capabilities, [])

      test "agent invokes through a real user-defined module" do
        assert {:ok, %{messages: messages}} =
                 Agent.invoke(@beamweaver_agent, @beamweaver_input, context: @beamweaver_context)

        assert Enum.any?(messages, &match?(%Message{role: :assistant}, &1))
      end

      if :tools in @beamweaver_capabilities do
        test "agent tool loop produces a matching tool message" do
          assert {:ok, %{messages: messages}} =
                   Agent.invoke(@beamweaver_agent, @beamweaver_input,
                     context: @beamweaver_context
                   )

          assert Enum.any?(messages, &match?(%Message{role: :tool}, &1))
        end
      end

      if :streaming in @beamweaver_capabilities do
        test "agent streams typed event envelopes" do
          assert {:ok, stream} =
                   Agent.stream_events(@beamweaver_agent, @beamweaver_input,
                     context: @beamweaver_context
                   )

          assert Enum.any?(stream, &match?(%Envelope{}, &1))
        end
      end

      if :checkpointing in @beamweaver_capabilities do
        test "agent works with an explicit checkpointer" do
          checkpointer = CheckpointETS.new()
          config = %{"configurable" => %{"thread_id" => inspect({@beamweaver_agent, self()})}}

          assert {:ok, %{messages: messages}} =
                   Agent.invoke(@beamweaver_agent, @beamweaver_input,
                     context: @beamweaver_context,
                     checkpointer: checkpointer,
                     config: config
                   )

          assert Enum.any?(messages, &match?(%Message{role: :assistant}, &1))

          assert {:ok, snapshot} =
                   Agent.get_state(@beamweaver_agent, checkpointer: checkpointer, config: config)

          assert is_map(snapshot.values)
        end
      end

      if :usage_metadata in @beamweaver_capabilities do
        test "agent records usage internally without leaking private state" do
          assert {:ok, state} =
                   Agent.invoke(@beamweaver_agent, @beamweaver_input,
                     context: @beamweaver_context
                   )

          refute Map.has_key?(state, :usage)
          refute Map.has_key?(state, :tool_set)
        end
      end
    end
  end
end
