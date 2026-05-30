defmodule BeamWeaver.Adapters.LivePostgresTest do
  use ExUnit.Case, async: false

  @moduletag :postgres

  alias BeamWeaver.Agent
  alias BeamWeaver.Agent.Middleware
  alias BeamWeaver.Agent.Subagent.AsyncTask
  alias BeamWeaver.Agent.Subagent.Spec
  alias BeamWeaver.Agent.Usage
  alias BeamWeaver.Cache
  alias BeamWeaver.Cache.Ecto, as: EctoCache
  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Checkpoint.Ecto, as: EctoCheckpoint
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Document
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.InvalidToolCall
  alias BeamWeaver.Core.Messages.ToolCall
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Filesystem
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Channels.DeltaSnapshot
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Graph.Execution.TaskRequest
  alias BeamWeaver.Graph.ExecutionInfo
  alias BeamWeaver.Graph.Messages.Remove
  alias BeamWeaver.Graph.Send
  alias BeamWeaver.Indexing.Record
  alias BeamWeaver.Indexing.RecordManager
  alias BeamWeaver.Indexing.RecordManager.EctoPostgres, as: EctoRecordManager
  alias BeamWeaver.Memory
  alias BeamWeaver.Memory.Ecto, as: EctoMemory
  alias BeamWeaver.Memory.GetOp
  alias BeamWeaver.Memory.ListNamespacesOp
  alias BeamWeaver.Memory.PutOp
  alias BeamWeaver.Memory.SearchOp
  alias BeamWeaver.Models.FakeChatModel
  alias BeamWeaver.Models.FakeEmbeddingModel
  alias BeamWeaver.Tracing.Exporters.LangSmith.QueueStore.Ecto, as: LangSmithQueueEcto
  alias BeamWeaver.Tracing.Run
  alias BeamWeaver.VectorStore
  alias BeamWeaver.VectorStore.EctoPostgres, as: EctoVectorStore

  setup do
    assert BeamWeaver.Test.LivePostgres.available?()
    :ok
  end

  defmodule ProviderError do
    defexception [:type, :message, details: %{}]
  end

  defmodule ProviderFailingModel do
    @behaviour BeamWeaver.Core.ChatModel

    defstruct []

    @impl true
    def invoke(%__MODULE__{}, _messages, _opts) do
      {:error,
       %ProviderError{
         type: :http_error,
         message: "provider authentication failed",
         details: %{status: 401, pid: self()}
       }}
    end
  end

  defmodule ProviderErrorCheckpointAgent do
    use BeamWeaver.Agent

    model(%ProviderFailingModel{})
  end

  defmodule UsageCheckpointModel do
    @behaviour BeamWeaver.Core.ChatModel

    defstruct []

    @impl true
    def invoke(%__MODULE__{}, _messages, _opts) do
      {:ok,
       BeamWeaver.Core.Message.assistant("with usage",
         usage_metadata: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}
       )}
    end
  end

  defmodule UsageCheckpointAgent do
    use BeamWeaver.Agent

    model(%UsageCheckpointModel{})
  end

  defmodule SubagentCheckpointParentModel do
    @behaviour BeamWeaver.Core.ChatModel

    alias BeamWeaver.Core.Message
    alias BeamWeaver.Core.Messages.ToolCall

    defstruct []

    @impl true
    def invoke(%__MODULE__{}, messages, _opts) do
      if Enum.any?(messages, &match?(%Message{role: :tool, name: "task"}, &1)) do
        {:ok, Message.assistant("parent done")}
      else
        call = %ToolCall{
          id: "call-child",
          call_id: "call-child",
          name: "task",
          args: %{
            "subagent_name" => "worker",
            "description" => "complete isolated child work"
          }
        }

        {:ok, Message.assistant("", tool_calls: [call])}
      end
    end
  end

  defmodule SubagentCheckpointChildModel do
    @behaviour BeamWeaver.Core.ChatModel

    alias BeamWeaver.Core.Message

    defstruct []

    @impl true
    def invoke(%__MODULE__{}, _messages, _opts), do: {:ok, Message.assistant("child done")}
  end

  test "checkpoint commits checkpoint and pending writes transactionally" do
    checkpoints = BeamWeaver.Test.LivePostgres.unique_table("bw_checkpoints")
    writes = BeamWeaver.Test.LivePostgres.unique_table("bw_writes")

    saver =
      EctoCheckpoint.new(
        repo: BeamWeaver.Test.PostgresRepo,
        checkpoints_table: checkpoints,
        writes_table: writes
      )

    migration = [adapters: [{:checkpoint, checkpoints_table: checkpoints, writes_table: writes}]]
    version = BeamWeaver.Test.LivePostgres.migrate(migration)

    on_exit(fn ->
      BeamWeaver.Test.LivePostgres.drop_tables([writes, checkpoints])
      BeamWeaver.Test.LivePostgres.clear_migration(version)
    end)

    config = %{"configurable" => %{"thread_id" => "thread-live"}}
    checkpoint = %{"id" => "cp-ok", "channel_values" => %{"answer" => 1}}

    assert {:ok, next_config} =
             Checkpoint.put_checkpoint_with_writes(
               saver,
               config,
               checkpoint,
               %{source: "loop", run_id: "run-live"},
               %{"answer" => 1},
               [{"answer", 1}],
               task_id: "task-ok",
               task_path: "node:ok"
             )

    assert %{pending_writes: [{"task-ok", "answer", 1}]} =
             Checkpoint.get_tuple(saver, next_config)

    bad_checkpoint = %{"id" => "cp-bad", "channel_values" => %{"answer" => 2}}

    assert {:error, _reason} =
             Checkpoint.put_checkpoint_with_writes(
               saver,
               config,
               bad_checkpoint,
               %{source: "loop"},
               %{},
               [{"bad", self()}],
               task_id: "task-bad"
             )

    refute Checkpoint.get_tuple(
             saver,
             %{"configurable" => %{"thread_id" => "thread-live", "checkpoint_id" => "cp-bad"}}
           )
  end

  test "checkpoint postgres saver matches metadata and pending-send behavior live" do
    checkpoints = BeamWeaver.Test.LivePostgres.unique_table("bw_checkpoints")
    writes = BeamWeaver.Test.LivePostgres.unique_table("bw_writes")

    saver =
      EctoCheckpoint.new(
        repo: BeamWeaver.Test.PostgresRepo,
        checkpoints_table: checkpoints,
        writes_table: writes
      )

    migration = [adapters: [{:checkpoint, checkpoints_table: checkpoints, writes_table: writes}]]
    version = BeamWeaver.Test.LivePostgres.migrate(migration)

    on_exit(fn ->
      BeamWeaver.Test.LivePostgres.drop_tables([writes, checkpoints])
      BeamWeaver.Test.LivePostgres.clear_migration(version)
    end)

    config = %{
      "configurable" => %{"thread_id" => "thread-live-checkpoint"},
      "metadata" => %{"run_id" => "run-from-config"}
    }

    {:ok, first} =
      Checkpoint.put(
        saver,
        config,
        %{"id" => "cp-parent", "channel_versions" => %{}},
        %{source: "loop", step: 1, custom_key: "\0abc"},
        %{}
      )

    assert %{checkpoint: parent_checkpoint, metadata: parent_metadata} =
             Checkpoint.get_tuple(saver, first)

    assert parent_checkpoint["channel_values"] == %{}
    assert parent_metadata["run_id"] == "run-from-config"
    assert parent_metadata["custom_key"] == "abc"

    assert :ok =
             Checkpoint.put_writes(
               saver,
               first,
               [{"__tasks__", "send-1"}, {"__tasks__", "send-2"}],
               "task-1"
             )

    {:ok, second} =
      Checkpoint.put(
        saver,
        first,
        %{"id" => "cp-child", "channel_versions" => %{}},
        %{source: "loop", step: 2},
        %{}
      )

    assert %{checkpoint: child_checkpoint} = Checkpoint.get_tuple(saver, second)
    assert child_checkpoint["channel_values"]["__tasks__"] == ["send-1", "send-2"]
    assert Map.has_key?(child_checkpoint["channel_versions"], "__tasks__")
  end

  test "compiled graph checkpoints ready-node metadata through live Postgres" do
    checkpoints = BeamWeaver.Test.LivePostgres.unique_table("bw_checkpoints_graph")
    writes = BeamWeaver.Test.LivePostgres.unique_table("bw_writes_graph")

    saver =
      EctoCheckpoint.new(
        repo: BeamWeaver.Test.PostgresRepo,
        checkpoints_table: checkpoints,
        writes_table: writes
      )

    migration = [adapters: [{:checkpoint, checkpoints_table: checkpoints, writes_table: writes}]]
    version = BeamWeaver.Test.LivePostgres.migrate(migration)

    on_exit(fn ->
      BeamWeaver.Test.LivePostgres.drop_tables([writes, checkpoints])
      BeamWeaver.Test.LivePostgres.clear_migration(version)
    end)

    graph =
      Graph.new()
      |> Graph.add_node(:first, fn _state -> %{value: 1} end)
      |> Graph.add_node(:second, fn state -> %{done: state[:value] + 1} end)
      |> Graph.add_edge(Graph.start(), :first)
      |> Graph.add_edge(:first, :second)
      |> Graph.add_edge(:second, Graph.end_node())
      |> Graph.compile!(checkpointer: saver)

    config = %{"configurable" => %{"thread_id" => "thread-live-graph"}}

    assert {:ok, %{done: 2, value: 1}} = Compiled.invoke(graph, %{}, config: config)

    {:ok, %{rows: rows}} =
      Ecto.Adapters.SQL.query(
        BeamWeaver.Test.PostgresRepo,
        """
        SELECT metadata->'nodes'
        FROM #{checkpoints}
        WHERE metadata ? 'nodes'
        ORDER BY checkpoint_id ASC
        """,
        []
      )

    assert Enum.map(rows, fn [nodes] -> nodes end) == [["first"], ["second"]]
  end

  test "agent provider errors with non-json details checkpoint through live Postgres" do
    checkpoints = BeamWeaver.Test.LivePostgres.unique_table("bw_checkpoints_model_error")
    writes = BeamWeaver.Test.LivePostgres.unique_table("bw_writes_model_error")

    saver =
      EctoCheckpoint.new(
        repo: BeamWeaver.Test.PostgresRepo,
        checkpoints_table: checkpoints,
        writes_table: writes
      )

    migration = [adapters: [{:checkpoint, checkpoints_table: checkpoints, writes_table: writes}]]
    version = BeamWeaver.Test.LivePostgres.migrate(migration)

    on_exit(fn ->
      BeamWeaver.Test.LivePostgres.drop_tables([writes, checkpoints])
      BeamWeaver.Test.LivePostgres.clear_migration(version)
    end)

    config = %{"configurable" => %{"thread_id" => "thread-live-model-error"}}

    assert {:error, %Error{type: :http_error, message: "provider authentication failed"} = error} =
             Agent.invoke(
               ProviderErrorCheckpointAgent,
               %{messages: [Message.user("hi")]},
               checkpointer: saver,
               config: config
             )

    assert error.details.status == 401
    assert error.details.pid =~ "#PID"

    {:ok, %{rows: [[stored_error]]}} =
      Ecto.Adapters.SQL.query(
        BeamWeaver.Test.PostgresRepo,
        "SELECT value FROM #{writes} WHERE channel = '__error__' LIMIT 1",
        []
      )

    assert stored_error["__beam_weaver_type__"] == "beam_weaver.core.error"
    assert stored_error["details"]["pid"] =~ "#PID"
  end

  test "agent checkpoint metadata drops private runtime channels through live Postgres" do
    checkpoints = BeamWeaver.Test.LivePostgres.unique_table("bw_checkpoints_agent_private")
    writes = BeamWeaver.Test.LivePostgres.unique_table("bw_writes_agent_private")

    saver =
      EctoCheckpoint.new(
        repo: BeamWeaver.Test.PostgresRepo,
        checkpoints_table: checkpoints,
        writes_table: writes
      )

    migration = [adapters: [{:checkpoint, checkpoints_table: checkpoints, writes_table: writes}]]
    version = BeamWeaver.Test.LivePostgres.migrate(migration)

    on_exit(fn ->
      BeamWeaver.Test.LivePostgres.drop_tables([writes, checkpoints])
      BeamWeaver.Test.LivePostgres.clear_migration(version)
    end)

    config = %{"configurable" => %{"thread_id" => "thread-live-agent-private"}}

    assert {:ok, %{messages: [_user, %Message{content: "with usage"}]}} =
             Agent.invoke(
               UsageCheckpointAgent,
               %{messages: [Message.user("hi")]},
               checkpointer: saver,
               config: config
             )

    {:ok, %{rows: rows}} =
      Ecto.Adapters.SQL.query(
        BeamWeaver.Test.PostgresRepo,
        """
        SELECT metadata, checkpoint
        FROM #{checkpoints}
        ORDER BY checkpoint_id ASC
        """,
        []
      )

    metadata_rows = Enum.map(rows, fn [metadata, _checkpoint] -> metadata end)

    refute Enum.any?(metadata_rows, fn metadata ->
             step_update = Map.get(metadata, "step_update", %{})
             Map.has_key?(step_update, "usage") or Map.has_key?(step_update, "tool_set")
           end)

    refute Enum.any?(metadata_rows, fn metadata ->
             updated_channels = Map.get(metadata, "updated_channels", [])
             "usage" in updated_channels or "tool_set" in updated_channels
           end)

    assert Enum.any?(metadata_rows, fn metadata ->
             case get_in(metadata, ["step_update", "messages"]) do
               [%{"content" => "with usage", "usage_metadata" => %{"total_tokens" => 2}} | _rest] ->
                 true

               _other ->
                 false
             end
           end)
  end

  test "checkpoint restore merges atom input into string-keyed message channel live" do
    checkpoints = BeamWeaver.Test.LivePostgres.unique_table("bw_checkpoints_message_alias")
    writes = BeamWeaver.Test.LivePostgres.unique_table("bw_writes_message_alias")

    saver =
      EctoCheckpoint.new(
        repo: BeamWeaver.Test.PostgresRepo,
        checkpoints_table: checkpoints,
        writes_table: writes
      )

    migration = [adapters: [{:checkpoint, checkpoints_table: checkpoints, writes_table: writes}]]
    version = BeamWeaver.Test.LivePostgres.migrate(migration)

    on_exit(fn ->
      BeamWeaver.Test.LivePostgres.drop_tables([writes, checkpoints])
      BeamWeaver.Test.LivePostgres.clear_migration(version)
    end)

    graph =
      Graph.new(state_schema: BeamWeaver.Graph.Messages.state_schema())
      |> Graph.add_node(:inspect_messages, fn state ->
        messages = BeamWeaver.Agent.State.messages(state)
        last = List.last(messages)

        %{
          seen_count: length(messages),
          last_role: last && last.role,
          state_keys: Enum.map(Map.keys(state), &to_string/1)
        }
      end)
      |> Graph.add_edge(Graph.start(), :inspect_messages)
      |> Graph.add_edge(:inspect_messages, Graph.end_node())
      |> Graph.compile!(checkpointer: saver)

    config = %{"configurable" => %{"thread_id" => "thread-live-message-alias"}}

    assert {:ok, %{seen_count: 2, last_role: :assistant}} =
             Compiled.invoke(
               graph,
               %{
                 messages: [
                   Message.user("original user"),
                   Message.assistant("needs tool",
                     tool_calls: [%ToolCall{id: "call-old", name: "lookup", args: %{}}]
                   )
                 ]
               },
               config: config
             )

    assert {:ok, %{seen_count: 3, last_role: :user, state_keys: keys}} =
             Compiled.invoke(graph, %{messages: [Message.user("retry user")]}, config: config)

    assert "messages" in keys
    assert Enum.count(keys, &(&1 == "messages")) == 1

    assert {:ok, %{rows: [[stored_messages]]}} =
             Ecto.Adapters.SQL.query(
               BeamWeaver.Test.PostgresRepo,
               """
               SELECT checkpoint->'channel_values'->'messages'
               FROM #{checkpoints}
               ORDER BY checkpoint_id DESC
               LIMIT 1
               """,
               []
             )

    assert length(stored_messages) == 3
    assert List.last(stored_messages)["content"] == "retry user"
  end

  test "checkpoint restore replays message pending writes from live Postgres" do
    checkpoints = BeamWeaver.Test.LivePostgres.unique_table("bw_checkpoints_pending_messages")
    writes = BeamWeaver.Test.LivePostgres.unique_table("bw_writes_pending_messages")

    saver =
      EctoCheckpoint.new(
        repo: BeamWeaver.Test.PostgresRepo,
        checkpoints_table: checkpoints,
        writes_table: writes
      )

    migration = [adapters: [{:checkpoint, checkpoints_table: checkpoints, writes_table: writes}]]
    version = BeamWeaver.Test.LivePostgres.migrate(migration)

    on_exit(fn ->
      BeamWeaver.Test.LivePostgres.drop_tables([writes, checkpoints])
      BeamWeaver.Test.LivePostgres.clear_migration(version)
    end)

    parent = self()

    pending_message =
      Message.assistant("pending assistant",
        tool_calls: [
          %ToolCall{
            id: "call-pending",
            name: "lookup",
            thought_signature: "sig-pending",
            args: %{"q" => "postgres"}
          }
        ]
      )

    graph =
      Graph.new(state_schema: BeamWeaver.Graph.Messages.state_schema())
      |> Graph.add_node(:fanout, fn _state ->
        [
          %Send{node: :ok, update: %{}},
          %Send{node: :fail, update: %{attempt: 1}}
        ]
      end)
      |> Graph.add_node(:ok, fn _state ->
        send(parent, :pending_message_ok_ran)
        %{messages: [pending_message]}
      end)
      |> Graph.add_node(:fail, fn state ->
        messages = BeamWeaver.Agent.State.messages(state)

        restored_pending? =
          Enum.any?(messages, fn
            %Message{content: "pending assistant", tool_calls: [%ToolCall{thought_signature: "sig-pending"}]} ->
              true

            _message ->
              false
          end)

        if state[:retry_ok] == true and restored_pending? do
          %{observed_pending_messages: length(messages)}
        else
          {:error, Error.new(:node_failed, "boom")}
        end
      end)
      |> Graph.add_edge(Graph.start(), :fanout)
      |> Graph.add_edge(:ok, Graph.end_node())
      |> Graph.add_edge(:fail, Graph.end_node())
      |> Graph.compile!(checkpointer: saver)

    config = %{"configurable" => %{"thread_id" => "thread-live-pending-messages"}}

    assert {:error, %Error{type: :node_failed}} =
             Compiled.invoke(graph, %{messages: [Message.user("start")]}, config: config)

    assert_receive :pending_message_ok_ran

    assert {:ok, snapshot} = Compiled.get_state(graph, config)

    assert Enum.any?(snapshot.pending_writes, fn
             {_task_id, "messages", [%Message{content: "pending assistant"}]} -> true
             _write -> false
           end)

    assert {:ok, %{observed_pending_messages: count}} =
             Compiled.invoke(graph, %{retry_ok: true}, config: config)

    assert count >= 2
    refute_receive :pending_message_ok_ran, 50

    assert {:ok, restored} = Compiled.get_state(graph, config)
    assert restored.pending_writes == []

    assert Enum.any?(BeamWeaver.Agent.State.messages(restored.values), fn
             %Message{content: "pending assistant", tool_calls: [%ToolCall{thought_signature: "sig-pending"}]} ->
               true

             _message ->
               false
           end)
  end

  test "checkpoint stores BeamWeaver structs as tagged jsonb and restores them live" do
    checkpoints = BeamWeaver.Test.LivePostgres.unique_table("bw_checkpoints_structs")
    writes = BeamWeaver.Test.LivePostgres.unique_table("bw_writes_structs")

    saver =
      EctoCheckpoint.new(
        repo: BeamWeaver.Test.PostgresRepo,
        checkpoints_table: checkpoints,
        writes_table: writes
      )

    migration = [adapters: [{:checkpoint, checkpoints_table: checkpoints, writes_table: writes}]]
    version = BeamWeaver.Test.LivePostgres.migrate(migration)

    on_exit(fn ->
      BeamWeaver.Test.LivePostgres.drop_tables([writes, checkpoints])
      BeamWeaver.Test.LivePostgres.clear_migration(version)
    end)

    config = %{"configurable" => %{"thread_id" => "thread-live-structs"}}

    user_message =
      Message.user("hello",
        metadata: %{source: :live_postgres},
        artifacts: [ContentBlock.text("artifact")]
      )

    assistant_message =
      Message.assistant(
        [
          %{
            type: :tool_call,
            id: "call-live",
            name: "lookup",
            args: %{"q" => "beam"},
            thought_signature: "sig-live"
          }
        ],
        tool_calls: [
          %ToolCall{
            id: "call-live",
            provider_id: "call-live",
            call_id: "call-live",
            name: "lookup",
            thought_signature: "sig-live",
            args: %{"q" => "beam"}
          }
        ],
        metadata: %{
          invalid_tool_calls: [
            %InvalidToolCall{id: "bad-live", name: "broken", args: "{", error: "invalid json"}
          ]
        }
      )

    assert {:ok, next_config} =
             Checkpoint.put(
               saver,
               config,
               %{
                 "id" => "cp-structs",
                 "channel_values" => %{
                   "async_tasks" => %{
                     "async-live" => %AsyncTask{
                       id: "async-live",
                       task_id: "async-live",
                       subagent_name: "research",
                       status: "running"
                     }
                   },
                   "execution_info" => %ExecutionInfo{
                     checkpoint_id: "cp-structs",
                     task_id: "task-structs",
                     thread_id: "thread-live-structs"
                   },
                   "files" => %{
                     "/conversation_history/summary.md" => %Filesystem.FileData{
                       content: "deal history",
                       encoding: "utf-8",
                       created_at: "2026-05-29T10:00:00Z",
                       modified_at: "2026-05-29T10:01:00Z"
                     }
                   },
                   "messages" => [user_message, assistant_message],
                   "snapshot" => %DeltaSnapshot{value: ["seed"]},
                   "block" => ContentBlock.text("inline block")
                 },
                 "channel_deltas" => %{"messages" => [%Remove{id: "old-message"}]},
                 "next_tasks" => [
                   TaskRequest.send(
                     "worker",
                     %{messages: [%Remove{id: "stale-message"}]},
                     ["__tasks__"],
                     timeout: 500
                   )
                 ]
               },
               %{
                 source: "loop",
                 run_id: "run-structs",
                 step_update: %{
                   usage: %Usage{
                     input_tokens: 12,
                     output_tokens: 3,
                     total_tokens: 15,
                     model_calls: 1
                   }
                 }
               },
               %{}
             )

    assert :ok =
             Checkpoint.put_writes(
               saver,
               next_config,
               [
                 {"messages",
                  Message.assistant("pending",
                    tool_calls: [%ToolCall{id: "call-pending", name: "lookup", args: %{}}]
                  )}
               ],
               "task-structs"
             )

    {:ok,
     %{
       rows: [
         [
           stored_file,
           stored_user_message,
           stored_assistant_tool_call,
           stored_invalid_tool_call,
           stored_async_task,
           stored_execution_info,
           stored_snapshot,
           stored_delta,
           stored_next_task,
           stored_usage,
           stored_write,
           stored_write_tool_call
         ]
       ]
     }} =
      Ecto.Adapters.SQL.query(
        BeamWeaver.Test.PostgresRepo,
        """
        SELECT
          checkpoint->'channel_values'->'files'->'/conversation_history/summary.md',
          checkpoint->'channel_values'->'messages'->0,
          checkpoint->'channel_values'->'messages'->1->'tool_calls'->0,
          checkpoint->'channel_values'->'messages'->1->'metadata'->'invalid_tool_calls'->0,
          checkpoint->'channel_values'->'async_tasks'->'async-live',
          checkpoint->'channel_values'->'execution_info',
          checkpoint->'channel_values'->'snapshot',
          checkpoint->'channel_deltas'->'messages'->0,
          checkpoint->'next_tasks'->0,
          metadata->'step_update'->'usage',
          value,
          value->'tool_calls'->0
        FROM #{checkpoints}
        JOIN #{writes}
          USING (thread_id, checkpoint_ns, checkpoint_id)
        WHERE #{checkpoints}.checkpoint_id = $1
        """,
        ["cp-structs"]
      )

    assert stored_file["__beam_weaver_type__"] == "beam_weaver.filesystem.file_data"
    assert stored_user_message["__beam_weaver_type__"] == "beam_weaver.core.message"

    assert stored_user_message["artifacts"] == [
             %{
               "__beam_weaver_type__" => "beam_weaver.core.content_block.text",
               "metadata" => %{},
               "text" => "artifact",
               "type" => %{"__beam_weaver_type__" => "atom", "value" => "text"}
             }
           ]

    assert stored_assistant_tool_call["__beam_weaver_type__"] ==
             "beam_weaver.core.messages.tool_call"

    assert stored_invalid_tool_call["__beam_weaver_type__"] ==
             "beam_weaver.core.messages.invalid_tool_call"

    assert stored_async_task["__beam_weaver_type__"] == "beam_weaver.agent.subagent.async_task"
    assert stored_execution_info["__beam_weaver_type__"] == "beam_weaver.graph.execution_info"
    assert stored_snapshot["__beam_weaver_type__"] == "beam_weaver.graph.channels.delta_snapshot"
    assert stored_delta["__beam_weaver_type__"] == "beam_weaver.graph.messages.remove"
    assert stored_next_task["__beam_weaver_type__"] == "beam_weaver.graph.execution.task_request"
    assert stored_usage["__beam_weaver_type__"] == "beam_weaver.agent.usage"
    assert stored_write["__beam_weaver_type__"] == "beam_weaver.core.message"

    assert stored_write_tool_call["__beam_weaver_type__"] ==
             "beam_weaver.core.messages.tool_call"

    restored = Checkpoint.get_tuple(saver, next_config)

    assert %{
             checkpoint: %{
               "channel_values" => %{
                 "async_tasks" => %{"async-live" => %AsyncTask{id: "async-live", status: "running"}},
                 "execution_info" => %ExecutionInfo{checkpoint_id: "cp-structs"},
                 "files" => %{
                   "/conversation_history/summary.md" => %Filesystem.FileData{
                     content: "deal history",
                     encoding: "utf-8"
                   }
                 },
                 "messages" => [
                   %Message{role: :user, metadata: %{"source" => :live_postgres}},
                   %Message{role: :assistant, tool_calls: [%ToolCall{id: "call-live"}]}
                 ],
                 "snapshot" => %DeltaSnapshot{value: ["seed"]},
                 "block" => %ContentBlock.Text{text: "inline block"}
               },
               "channel_deltas" => %{"messages" => [%Remove{id: "old-message"}]},
               "next_tasks" => [%TaskRequest{node: "worker", kind: :send, timeout: 500}]
             },
             metadata: %{
               "run_id" => "run-structs",
               "step_update" => %{
                 "usage" => %Usage{
                   input_tokens: 12,
                   output_tokens: 3,
                   total_tokens: 15,
                   model_calls: 1
                 }
               }
             },
             pending_writes: [
               {"task-structs", "messages",
                %Message{role: :assistant, content: "pending", tool_calls: [%ToolCall{id: "call-pending"}]}}
             ]
           } = restored

    [_, restored_assistant] = restored.checkpoint["channel_values"]["messages"]

    assert %Message{
             content: [
               %{
                 type: :tool_call,
                 id: "call-live",
                 name: "lookup",
                 args: %{"q" => "beam"},
                 thought_signature: "sig-live"
               }
             ],
             tool_calls: [%ToolCall{id: "call-live", thought_signature: "sig-live"}]
           } = restored_assistant

    assert {:ok,
            {nil,
             [
               %{
                 "parts" => [
                   %{
                     "functionCall" => %{
                       "name" => "lookup",
                       "args" => %{"q" => "beam"}
                     }
                   }
                 ]
               }
             ]}} = BeamWeaver.Google.Messages.encode_messages([restored_assistant])
  end

  test "task subagent checkpoints with string-key config through live Postgres" do
    checkpoints = BeamWeaver.Test.LivePostgres.unique_table("bw_checkpoints_subagent")
    writes = BeamWeaver.Test.LivePostgres.unique_table("bw_writes_subagent")

    saver =
      EctoCheckpoint.new(
        repo: BeamWeaver.Test.PostgresRepo,
        checkpoints_table: checkpoints,
        writes_table: writes
      )

    migration = [adapters: [{:checkpoint, checkpoints_table: checkpoints, writes_table: writes}]]
    version = BeamWeaver.Test.LivePostgres.migrate(migration)

    on_exit(fn ->
      BeamWeaver.Test.LivePostgres.drop_tables([writes, checkpoints])
      BeamWeaver.Test.LivePostgres.clear_migration(version)
    end)

    middleware =
      Middleware.Subagents.new(
        model: %FakeChatModel{response: "live child done"},
        summarization: false,
        compact_conversation: false,
        checkpointer: saver,
        subagents: [
          %Spec{
            name: "worker",
            description: "Worker",
            system_prompt: "You are a worker."
          }
        ]
      )

    task_tool = middleware |> Middleware.Subagents.tools() |> hd()
    thread_id = "thread-live-subagent-#{System.unique_integer([:positive])}"

    assert {:ok, %Command{update: %{messages: [%Message{content: "live child done"}]}}} =
             Tool.invoke(task_tool, %{
               "subagent_name" => "worker",
               "description" => "do live child work",
               state: %{},
               runtime: %{
                 node: "tools",
                 task_id: "tool-node-task",
                 config: %{"configurable" => %{"thread_id" => thread_id}}
               },
               tool_call_id: "call-live-subagent"
             })

    {:ok, %{rows: rows}} =
      Ecto.Adapters.SQL.query(
        BeamWeaver.Test.PostgresRepo,
        """
        SELECT checkpoint_ns, count(*)
        FROM #{checkpoints}
        WHERE thread_id = $1
        GROUP BY checkpoint_ns
        ORDER BY checkpoint_ns
        """,
        [thread_id]
      )

    assert rows != []
    refute Enum.any?(rows, fn [namespace, _count] -> namespace == "" end)

    assert Enum.any?(rows, fn [namespace, count] ->
             is_binary(namespace) and String.contains?(namespace, "subagent.worker") and count > 0
           end)
  end

  test "agent task subagent keeps child checkpoints out of the parent root namespace live" do
    checkpoints = BeamWeaver.Test.LivePostgres.unique_table("bw_checkpoints_subagent_agent")
    writes = BeamWeaver.Test.LivePostgres.unique_table("bw_writes_subagent_agent")

    saver =
      EctoCheckpoint.new(
        repo: BeamWeaver.Test.PostgresRepo,
        checkpoints_table: checkpoints,
        writes_table: writes
      )

    migration = [adapters: [{:checkpoint, checkpoints_table: checkpoints, writes_table: writes}]]
    version = BeamWeaver.Test.LivePostgres.migrate(migration)

    on_exit(fn ->
      BeamWeaver.Test.LivePostgres.drop_tables([writes, checkpoints])
      BeamWeaver.Test.LivePostgres.clear_migration(version)
    end)

    {:ok, agent} =
      Agent.build(
        name: "postgres_subagent_parent",
        model: %SubagentCheckpointParentModel{},
        checkpointer: saver,
        compact_conversation: false,
        subagents: [
          %Spec{
            name: "worker",
            description: "Worker",
            model: %SubagentCheckpointChildModel{},
            system_prompt: "You are a worker."
          }
        ]
      )

    thread_id = "thread-live-subagent-agent-#{System.unique_integer([:positive])}"

    assert {:ok, %{messages: messages}} =
             Agent.invoke(agent, %{messages: [Message.user("parent")]},
               config: %{"configurable" => %{"thread_id" => thread_id}}
             )

    assert Enum.any?(messages, &match?(%Message{role: :assistant, content: "parent done"}, &1))

    {:ok, %{rows: rows}} =
      Ecto.Adapters.SQL.query(
        BeamWeaver.Test.PostgresRepo,
        """
        SELECT checkpoint_ns, count(*)
        FROM #{checkpoints}
        WHERE thread_id = $1
        GROUP BY checkpoint_ns
        ORDER BY checkpoint_ns
        """,
        [thread_id]
      )

    assert Enum.any?(rows, fn [namespace, count] -> namespace == "" and count > 0 end)

    assert Enum.any?(rows, fn [namespace, count] ->
             is_binary(namespace) and String.contains?(namespace, "subagent.worker") and count > 0
           end)
  end

  test "checkpoint shallow postgres saver keeps only the latest checkpoint live" do
    checkpoints = BeamWeaver.Test.LivePostgres.unique_table("bw_checkpoints_shallow")
    writes = BeamWeaver.Test.LivePostgres.unique_table("bw_writes_shallow")

    saver =
      EctoCheckpoint.new(
        repo: BeamWeaver.Test.PostgresRepo,
        checkpoints_table: checkpoints,
        writes_table: writes,
        shallow?: true
      )

    migration = [adapters: [{:checkpoint, checkpoints_table: checkpoints, writes_table: writes}]]
    version = BeamWeaver.Test.LivePostgres.migrate(migration)

    on_exit(fn ->
      BeamWeaver.Test.LivePostgres.drop_tables([writes, checkpoints])
      BeamWeaver.Test.LivePostgres.clear_migration(version)
    end)

    config = %{"configurable" => %{"thread_id" => "thread-live-shallow"}}

    {:ok, first_config} =
      Checkpoint.put(
        saver,
        config,
        %{"id" => "cp-shallow-1", "channel_values" => %{"step" => 1}},
        %{source: "loop"},
        %{"step" => 1}
      )

    assert :ok = Checkpoint.put_writes(saver, first_config, [{"step", 1}], "task-live")

    {:ok, second_config} =
      Checkpoint.put(
        saver,
        first_config,
        %{"id" => "cp-shallow-2", "channel_values" => %{"step" => 2}},
        %{source: "loop"},
        %{"step" => 2}
      )

    assert [%{checkpoint: %{"id" => "cp-shallow-2"}, pending_writes: []}] =
             Checkpoint.list(saver, config)

    refute Checkpoint.get_tuple(saver, first_config)

    assert %{checkpoint: %{"id" => "cp-shallow-2"}, parent_config: nil} =
             Checkpoint.get_tuple(saver, second_config)
  end

  test "cache stores safe serialized values, TTLs, sweep, and namespace clear" do
    table = BeamWeaver.Test.LivePostgres.unique_table("bw_cache")

    cache =
      EctoCache.new(
        repo: BeamWeaver.Test.PostgresRepo,
        table: table
      )

    version = BeamWeaver.Test.LivePostgres.migrate(adapters: [{:cache, table: table}])

    on_exit(fn ->
      BeamWeaver.Test.LivePostgres.drop_tables([table])
      BeamWeaver.Test.LivePostgres.clear_migration(version)
    end)

    assert :ok =
             Cache.put(cache, [:tenant, "a"], %{id: 1}, %{"answer" => 42}, metadata: %{model: "fake"})

    assert {:hit, %{"answer" => 42}, %{"model" => "fake"}} =
             Cache.lookup(cache, [:tenant, "a"], %{id: 1})

    {:ok, %{rows: [[blob]]}} =
      Ecto.Adapters.SQL.query(
        BeamWeaver.Test.PostgresRepo,
        "SELECT value FROM #{table} LIMIT 1",
        []
      )

    refute match?(<<131, _::binary>>, blob)

    assert :ok = Cache.put(cache, :ttl, "key", "gone", ttl: 1)
    Process.sleep(5)
    assert {:ok, _count} = EctoCache.sweep_expired(cache)
    assert :miss = Cache.lookup(cache, :ttl, "key")

    assert :ok = Cache.clear(cache, [:tenant, "a"])
    assert :miss = Cache.lookup(cache, [:tenant, "a"], %{id: 1})
  end

  test "cache rejects corrupt values and legacy ETF payloads through the public codec path" do
    table = BeamWeaver.Test.LivePostgres.unique_table("bw_cache_codec")

    cache =
      EctoCache.new(
        repo: BeamWeaver.Test.PostgresRepo,
        table: table
      )

    version = BeamWeaver.Test.LivePostgres.migrate(adapters: [{:cache, table: table}])

    on_exit(fn ->
      BeamWeaver.Test.LivePostgres.drop_tables([table])
      BeamWeaver.Test.LivePostgres.clear_migration(version)
    end)

    namespace = [:tenant, "legacy"]
    corrupt_key = "corrupt"
    legacy_key = "legacy-etf"

    assert {:ok, _result} =
             Ecto.Adapters.SQL.query(
               BeamWeaver.Test.PostgresRepo,
               """
               INSERT INTO #{table} (namespace, key, value, metadata, expires_at)
               VALUES ($1, $2, $3, $4, NULL), ($5, $6, $7, $8, NULL)
               """,
               [
                 Cache.stable_key(namespace),
                 Cache.stable_key(corrupt_key),
                 "not-json",
                 %{},
                 Cache.stable_key(namespace),
                 Cache.stable_key(legacy_key),
                 :erlang.term_to_binary(%{"legacy" => true}),
                 %{}
               ]
             )

    assert {:error, %BeamWeaver.Core.Error{type: :serialization_error}} =
             Cache.lookup(cache, namespace, corrupt_key)

    assert {:error, %BeamWeaver.Core.Error{type: :serialization_error}} =
             Cache.lookup(cache, namespace, legacy_key)

    refute Map.has_key?(cache.serialization, :trusted_local_etf?)
  end

  test "memory store batch order, namespace filters, nested filters, and ttl refresh work live" do
    table = BeamWeaver.Test.LivePostgres.unique_table("bw_memory")

    store =
      EctoMemory.new(
        repo: BeamWeaver.Test.PostgresRepo,
        table: table,
        refresh_on_read?: true,
        default_ttl: 0.01
      )

    version = BeamWeaver.Test.LivePostgres.migrate(adapters: [{:memory, table: table}])

    on_exit(fn ->
      BeamWeaver.Test.LivePostgres.drop_tables([table])
      BeamWeaver.Test.LivePostgres.clear_migration(version)
    end)

    ops = [
      %PutOp{
        namespace: ["tenant", "docs"],
        key: "a",
        value: %{"nested" => %{"rank" => 2}},
        ttl: 0.01
      },
      %PutOp{namespace: ["tenant", "docs"], key: "b", value: %{"nested" => %{"rank" => 4}}},
      %SearchOp{namespace: ["tenant"], filter: %{"nested.rank" => %{"$gte" => 3}}, limit: 10},
      %ListNamespacesOp{match_conditions: [], max_depth: 2, limit: 10},
      %GetOp{namespace: ["tenant", "docs"], key: "a"}
    ]

    assert [nil, nil, [%{key: "b"}], namespaces, %{key: "a", expires_at: refreshed}] =
             Memory.batch(store, ops)

    assert ["tenant", "docs"] in namespaces
    assert refreshed

    assert {:ok, _count} = EctoMemory.sweep_expired(store)
  end

  test "pgvector adapter setup, search, score, MMR, and delete work live" do
    table = BeamWeaver.Test.LivePostgres.unique_table("bw_vectors")

    store =
      EctoVectorStore.new(
        repo: BeamWeaver.Test.PostgresRepo,
        table: table,
        namespace: "tenant-a",
        embedding: %FakeEmbeddingModel{dimensions: 3},
        dimensions: 3,
        index: :hnsw
      )

    version =
      BeamWeaver.Test.LivePostgres.migrate(
        adapters: [
          {:vector_store, table: table, dimensions: 3, index: :hnsw}
        ]
      )

    on_exit(fn ->
      BeamWeaver.Test.LivePostgres.drop_tables([table])
      BeamWeaver.Test.LivePostgres.clear_migration(version)
    end)

    docs = [
      Document.new!("alpha document", metadata: %{group: "a", nested: %{rank: 1}}),
      Document.new!("beta document", metadata: %{group: "b", nested: %{rank: 3}})
    ]

    assert {:ok, [id1, id2]} = VectorStore.add_documents(store, docs)

    assert {:ok, [{%Document{} = doc, score} | _]} =
             VectorStore.similarity_search_with_score(store, "beta", k: 2)

    assert is_binary(doc.content)
    assert is_number(score)

    assert {:ok, [%Document{content: "beta document"}]} =
             VectorStore.similarity_search(store, "beta",
               k: 2,
               filter: %{"nested.rank" => %{gte: 2}}
             )

    assert {:ok, [%Document{} | _]} =
             VectorStore.max_marginal_relevance_search(store, "alpha", k: 1)

    assert :ok = VectorStore.delete(store, [id1, id2])
    assert {:ok, []} = VectorStore.similarity_search(store, "alpha", k: 2)
  end

  test "record manager stores and filters indexing records live" do
    table = BeamWeaver.Test.LivePostgres.unique_table("bw_records")

    manager =
      EctoRecordManager.new(
        repo: BeamWeaver.Test.PostgresRepo,
        table: table,
        namespace: "tenant-a"
      )

    version = BeamWeaver.Test.LivePostgres.migrate(adapters: [{:record_manager, table: table}])

    on_exit(fn ->
      BeamWeaver.Test.LivePostgres.drop_tables([table])
      BeamWeaver.Test.LivePostgres.clear_migration(version)
    end)

    assert :ok =
             RecordManager.put(manager, %Record{
               id: "doc-1",
               source_id: "source-a",
               hash: "hash-a",
               metadata: %{kind: "live"}
             })

    assert {:ok, %Record{id: "doc-1", metadata: %{"kind" => "live"}}} =
             RecordManager.get(manager, "doc-1")

    assert {:ok, [%Record{id: "doc-1"}]} =
             RecordManager.list(manager, source_ids: ["source-a"])

    assert :ok = RecordManager.delete(manager, ["doc-1"])
    assert {:ok, nil} = RecordManager.get(manager, "doc-1")
  end

  test "LangSmith queue store persists safe serialized queue items live" do
    table = BeamWeaver.Test.LivePostgres.unique_table("bw_langsmith_queue")

    store =
      LangSmithQueueEcto.new(
        repo: BeamWeaver.Test.PostgresRepo,
        table: table
      )

    version = BeamWeaver.Test.LivePostgres.migrate(adapters: [{:langsmith_queue, table: table}])

    on_exit(fn ->
      BeamWeaver.Test.LivePostgres.drop_tables([table])
      BeamWeaver.Test.LivePostgres.clear_migration(version)
    end)

    item = %{
      id: "queue-item-1",
      event: :ok,
      run:
        Run.new("queued",
          id: "run-live-queue",
          trace_id: "trace-live-queue",
          kind: :graph,
          started_at: ~U[2026-05-22 00:00:00Z],
          metadata: %{nested: %{rank: 1}}
        ),
      opts: [],
      attempts: 0,
      retry_at: 0,
      enqueued_at: 1
    }

    assert :ok = LangSmithQueueEcto.put(store, item)

    assert [%{id: "queue-item-1", run: %Run{id: "run-live-queue"}}] =
             LangSmithQueueEcto.list(store, [])

    {:ok, %{rows: [[blob]]}} =
      Ecto.Adapters.SQL.query(
        BeamWeaver.Test.PostgresRepo,
        "SELECT item FROM #{table} LIMIT 1",
        []
      )

    refute match?(<<131, _::binary>>, blob)

    assert :ok = LangSmithQueueEcto.delete(store, "queue-item-1")
    assert [] = LangSmithQueueEcto.list(store, [])
  end
end
