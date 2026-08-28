defmodule BeamWeaver.CompactionTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Compaction

  alias BeamWeaver.Compaction.{
    Canonical,
    Checkpoint,
    InputEvent,
    Policy,
    RehydrationState,
    Request,
    Semantic,
    State,
    ToolProjection
  }

  alias BeamWeaver.Core.ID
  alias BeamWeaver.Models.Profile

  test "portable compaction keeps a safe tail and validates source-backed semantic output" do
    events = events()
    first_user_id = hd(events).event_id

    summarize = fn payload ->
      first = payload.covered_range.first_chat_seq
      last = payload.covered_range.last_chat_seq

      {:ok, semantic(first_user_id, first, last), %{input_tokens: 100, output_tokens: 20}}
    end

    request = request(events, summarize)
    assert {:ok, result} = Compaction.compact(%{}, request)
    assert result.status == :compacted
    assert result.compaction_checkpoint.checkpoint_id == request.request_id
    assert result.tokens_after < result.tokens_before
    assert result.compaction_checkpoint.representation == :portable
    assert Checkpoint.to_map(result.compaction_checkpoint).accounting_method == "conservative_utf8"
    assert %Semantic{} = result.compaction_checkpoint.semantic
    assert Enum.map(result.retained_events, & &1.role) |> hd() != :tool
    assert result.compaction_checkpoint.summary_coverage_last_chat_seq < 6
  end

  test "provider usage floors only the request whose bytes it measured" do
    events = events()
    first_user_id = hd(events).event_id

    request =
      request(events, fn payload ->
        {:ok,
         semantic(
           first_user_id,
           payload.covered_range.first_chat_seq,
           payload.covered_range.last_chat_seq
         )}
      end)
      |> Map.put(:accounting, %{reported_input_tokens: 19_500})

    assert {:ok, result} = Compaction.compact(%{}, request)
    assert result.status == :compacted
    assert result.tokens_before == 19_500
    assert result.tokens_after < result.tokens_before
  end

  test "invalid semantic output is repaired once without mutating source events" do
    events = events()
    original = :erlang.term_to_binary(events)
    first_user_id = hd(events).event_id
    counter = :counters.new(1, [])

    summarize = fn payload ->
      :counters.add(counter, 1, 1)

      if Map.has_key?(payload, :repair) do
        {:ok,
         semantic(
           first_user_id,
           payload.covered_range.first_chat_seq,
           payload.covered_range.last_chat_seq
         )}
      else
        {:ok, %{"unexpected" => true}}
      end
    end

    assert {:ok, result} = Compaction.compact(%{}, request(events, summarize))
    assert result.status == :compacted
    assert :counters.get(counter, 1) == 2
    assert :erlang.term_to_binary(events) == original
  end

  test "a later compaction keeps the immutable parent and cumulative semantic lineage" do
    first_events = events()
    first_source_id = hd(first_events).event_id

    first_request =
      request(first_events, fn payload ->
        {:ok,
         semantic(
           first_source_id,
           payload.covered_range.first_chat_seq,
           payload.covered_range.last_chat_seq
         )}
      end)

    assert {:ok, first_result} = Compaction.compact(%{}, first_request)
    first_checkpoint = first_result.compaction_checkpoint
    frozen_parent = :erlang.term_to_binary(first_checkpoint)
    run_agent_id = first_request.run_agent_id

    later_events = [
      event(run_agent_id, 7, :user, "continue from the compacted history"),
      event(run_agent_id, 8, :assistant, String.duplicate("new work ", 1_000)),
      event(run_agent_id, 9, :user, "keep the new decision"),
      event(run_agent_id, 10, :assistant, "continuing")
    ]

    later_source_id = hd(later_events).event_id

    second_request = %{
      first_request
      | request_id: ID.uuidv7(),
        parent_checkpoint_id: first_checkpoint.checkpoint_id,
        previous_semantic: first_checkpoint.semantic,
        events: later_events,
        active_input_event_ids: [List.last(later_events).event_id],
        rendered_request: String.duplicate("y", 18_000),
        summarize: fn payload ->
          {:ok,
           semantic(
             later_source_id,
             payload.covered_range.first_chat_seq,
             payload.covered_range.last_chat_seq
           )}
        end
    }

    assert {:ok, second_result} = Compaction.compact(%{}, second_request)
    assert second_result.compaction_checkpoint.parent_checkpoint_id == first_checkpoint.checkpoint_id
    assert :erlang.term_to_binary(first_checkpoint) == frozen_parent
  end

  test "automatic check below trigger is skipped without calling the model" do
    events = events()

    request =
      request(events, fn _payload -> flunk("summarizer must not run") end)
      |> Map.put(:trigger, :auto)
      |> Map.put(:rendered_request, "small")

    assert {:ok, result} = Compaction.compact(%{}, request)
    assert result.status == :skipped
    assert result.provider_usage.suppression == :below_trigger
  end

  test "structural pressure cannot be skipped by the token trigger" do
    events = events()
    first_user_id = hd(events).event_id
    counter = :counters.new(1, [])

    summarize = fn payload ->
      :counters.add(counter, 1, 1)

      {:ok,
       semantic(
         first_user_id,
         payload.covered_range.first_chat_seq,
         payload.covered_range.last_chat_seq
       )}
    end

    request =
      request(events, summarize)
      |> Map.put(:trigger, :auto)
      |> Map.put(:structural_pressure, true)
      |> Map.put(:rendered_request, String.duplicate("x", 10_000))

    assert {:ok, result} = Compaction.compact(%{}, request)
    assert result.status == :compacted
    assert :counters.get(counter, 1) > 0
  end

  test "semantic artifact references require host-proven source event provenance" do
    events = events()
    first_user_id = hd(events).event_id
    tool_event = Enum.find(events, &(&1.role == :tool))
    [artifact_id] = tool_event.artifact_ids

    summarize = fn payload ->
      output =
        semantic(
          first_user_id,
          payload.covered_range.first_chat_seq,
          payload.covered_range.last_chat_seq
        )
        |> Map.put("artifact_refs", [
          %{
            "artifact_id" => artifact_id,
            "purpose" => "Retain the durable tool result",
            "source_event_ids" => [first_user_id]
          }
        ])

      {:ok, output}
    end

    assert {:error, error} = Compaction.compact(%{}, request(events, summarize))
    assert error.type == :invalid_compaction_semantic
    assert error.message =~ "host source provenance"
  end

  test "large tool projection requires a durable artifact" do
    events = events() |> List.update_at(1, &%{&1 | artifact_ids: []})
    tool = Enum.at(events, 1)

    events =
      List.replace_at(events, 1, %{
        tool
        | content_hash:
            Canonical.hash(%{
              content: tool.content,
              tool: tool.tool,
              artifact_ids: [],
              truncated: false
            })
      })

    assert {:error, error} =
             Compaction.compact(%{}, request(events, fn _payload -> flunk("must not run") end))

    assert error.type == :missing_compaction_artifact
  end

  test "compaction state accepts its persisted JSON representation" do
    persisted =
      %State{successful_auto_compactions: 1, overflow_retry_used: true}
      |> Map.from_struct()
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)

    assert {:ok, %State{successful_auto_compactions: 1, overflow_retry_used: true}} =
             State.new(persisted)
  end

  test "compaction policy accepts its persisted JSON representation" do
    persisted =
      %Policy{}
      |> Map.from_struct()
      |> Map.new(fn {key, value} ->
        value = if is_atom(value) and not is_boolean(value), do: Atom.to_string(value), else: value
        {Atom.to_string(key), value}
      end)

    assert {:ok, %Policy{mode: :portable, model: :current_task_model}} = Policy.new(persisted)

    assert {:error, %{type: :invalid_compaction_policy}} = Policy.new(%{"mode" => "detached"})
    assert {:error, %{type: :invalid_compaction_policy}} = Policy.new(%{"model" => nil})
    assert {:error, %{type: :invalid_compaction_policy}} = Policy.new(%Policy{model: []})
  end

  test "closed compaction values reject normalized duplicate fields" do
    assert {:error, %{type: :invalid_compaction_policy}} =
             Policy.new(%{:version => 1, "version" => 1})

    assert {:error, %{type: :invalid_compaction_state}} =
             State.new(%{:overflow_retry_used => false, "overflow_retry_used" => false})

    event = events() |> hd() |> Map.from_struct()

    assert {:error, %{type: :invalid_compaction_event}} =
             InputEvent.new(Map.put(event, "event_id", event.event_id))

    semantic = semantic(ID.uuidv7(), 1, 1)

    assert {:error, %{type: :invalid_compaction_semantic}} =
             Semantic.new(Map.put(semantic, :version, 1))
  end

  test "compaction requests reject invalid focus and duplicate lane ordinals" do
    request = request(events(), fn _payload -> flunk("summarizer must not run") end)

    assert {:error, %{type: :invalid_compaction_request}} =
             Request.new(%{request | focus: :not_text})

    [first, second | rest] = request.events

    assert {:error, %{type: :invalid_compaction_request}} =
             Request.new(%{request | events: [first, %{second | lane_event_ordinal: 1} | rest]})
  end

  test "compaction state advances automatic and overflow circuit evidence" do
    assert {:ok, observed} = State.observe_new_tokens(%State{}, 12_000)
    assert observed.new_tokens_since_compaction == 12_000

    assert {:ok, automatic} = State.record_success(observed, :auto, 9, 20_000)
    assert automatic.successful_auto_compactions == 1
    assert automatic.new_tokens_since_compaction == 0

    assert {:ok, overflow} = State.record_success(automatic, :overflow, 12, 18_000)
    assert overflow.overflow_retry_used
    assert overflow.successful_auto_compactions == 1
  end

  test "accounting identity changes reset only unit-dependent anti-thrash state" do
    state = %State{
      accounting_method: :conservative_utf8,
      accounting_version: 1,
      accounting_profile_hash: String.duplicate("a", 64),
      last_compaction_tokens_after: 9_000,
      new_tokens_since_compaction: 1_000,
      last_compaction_lane_event_ordinal: 8,
      consecutive_ineffective_compactions: 2,
      successful_auto_compactions: 2,
      overflow_retry_used: true,
      cancellation_pending: true
    }

    assert {:ok, rebased} =
             State.rebase_accounting(state, %{
               method: :local_tokenizer_v1,
               version: 1,
               profile_hash: String.duplicate("b", 64)
             })

    assert rebased.last_compaction_tokens_after == nil
    assert rebased.new_tokens_since_compaction == 0
    assert rebased.last_compaction_lane_event_ordinal == nil
    assert rebased.consecutive_ineffective_compactions == 0
    assert rebased.successful_auto_compactions == 2
    assert rebased.overflow_retry_used
    assert rebased.cancellation_pending
  end

  test "accounting identity rebasing accepts the persisted string method" do
    profile_hash = String.duplicate("a", 64)

    assert {:ok, state} =
             State.rebase_accounting(%State{}, %{
               "method" => "local_tokenizer_v1",
               "version" => 1,
               "profile_hash" => profile_hash
             })

    assert state.accounting_method == :local_tokenizer_v1
    assert state.accounting_version == 1
    assert state.accounting_profile_hash == profile_hash
  end

  test "compaction state restores accounting identity from persisted JSON values" do
    attrs = %{
      "accounting_method" => "local_tokenizer_v1",
      "accounting_version" => 1,
      "accounting_profile_hash" => String.duplicate("a", 64)
    }

    assert {:ok, %State{accounting_method: :local_tokenizer_v1}} = State.new(attrs)

    assert {:error, %{type: :invalid_compaction_state}} =
             State.new(%{attrs | "accounting_method" => "untrusted_counter"})
  end

  test "tool projections replay from immutable source evidence and reject tampering" do
    raw_events = events()

    assert {:ok, projected, [manifest]} =
             ToolProjection.project(raw_events, MapSet.new())

    projected_tool = Enum.find(projected, &(&1.role == :tool))
    assert projected_tool.content == nil
    assert projected_tool.truncated

    assert {:ok, replayed} = ToolProjection.replay(raw_events, [manifest])
    assert Enum.find(replayed, &(&1.role == :tool)) == projected_tool

    tampered =
      Enum.map(raw_events, fn
        %{role: :tool} = event -> %{event | content_hash: String.duplicate("f", 64)}
        event -> event
      end)

    assert {:error, %{type: :invalid_compaction_projection}} = ToolProjection.replay(tampered, [manifest])
  end

  test "semantic JSON schema is closed and derived from the authoritative fields" do
    schema = Semantic.json_schema()

    assert schema["additionalProperties"] == false
    assert schema["required"] == Enum.map(Semantic.fields(), &Atom.to_string/1)
    assert schema["properties"]["critical_context"]["maxItems"] == Semantic.bounds().critical_context
  end

  defp request(events, summarize) do
    {:ok, policy} =
      Policy.new(%{
        recent_tail_min_tokens: 100,
        recent_tail_max_tokens: 100,
        summary_output_min_tokens: 10,
        summary_output_max_tokens: 100,
        minimum_prune_reclaim_tokens: 100_000,
        minimum_total_reclaim_tokens: 1,
        minimum_total_reclaim_ratio: 0.01
      })

    {:ok, rehydration} = RehydrationState.new(%{"todo" => %{"revision" => 1}})

    %Request{
      request_id: ID.uuidv7(),
      trigger: :manual,
      thread_id: ID.uuidv7(),
      run_id: ID.uuidv7(),
      root_turn_id: ID.uuidv7(),
      run_agent_id: hd(events).run_agent_id,
      checkpoint_namespace: "root",
      provider_connection_id: ID.uuidv7(),
      destination_identity_hash: String.duplicate("a", 64),
      model_profile: %Profile{max_input_tokens: 20_000, max_output_tokens: 2_000},
      rendered_request: String.duplicate("x", 18_000),
      events: events,
      active_input_event_ids: [List.last(events).event_id],
      rehydration_state: rehydration,
      policy: policy,
      render: fn semantic, retained ->
        Canonical.encode(%{
          semantic: semantic && Semantic.to_map(semantic),
          events: Enum.map(retained, &BeamWeaver.Compaction.InputEvent.to_map/1)
        })
      end,
      summarize: summarize
    }
  end

  defp events do
    run_agent_id = ID.uuidv7()
    artifact_id = ID.uuidv7()

    [
      event(run_agent_id, 1, :user, "implement the requested behavior"),
      event(run_agent_id, 2, :tool, String.duplicate("tool output ", 500), artifact_id),
      event(run_agent_id, 3, :user, "keep the API small"),
      event(run_agent_id, 4, :assistant, "working"),
      event(run_agent_id, 5, :user, "continue"),
      event(run_agent_id, 6, :assistant, "still working")
    ]
  end

  defp event(run_agent_id, ordinal, role, content, artifact_id \\ nil) do
    provenance = %{"origin" => if(role == :user, do: "direct_user", else: "derived")}

    tool =
      if role == :tool,
        do: %{"call_id" => "call-1", "name" => "test", "status" => "success"},
        else: nil

    artifact_ids = if artifact_id, do: [artifact_id], else: []

    payload = %{content: content, tool: tool, artifact_ids: artifact_ids, truncated: false}

    %{
      event_id: ID.uuidv7(),
      chat_seq: ordinal,
      run_agent_id: run_agent_id,
      checkpoint_namespace: "root",
      lane_event_ordinal: ordinal,
      role: role,
      provenance: provenance,
      provenance_sha256: Canonical.hash(provenance),
      content: content,
      tool: tool,
      artifact_ids: artifact_ids,
      truncated: false,
      content_hash: Canonical.hash(payload),
      token_count: byte_size(content),
      protected: ordinal == 5
    }
    |> BeamWeaver.Compaction.InputEvent.new()
    |> elem(1)
  end

  defp semantic(first_user_id, first, last) do
    %{
      "version" => 1,
      "objective" => [
        %{"text" => "Implement the requested behavior", "source_event_ids" => [first_user_id]}
      ],
      "user_requests" => [
        %{
          "source_event_id" => first_user_id,
          "exact_excerpt" => "implement the requested behavior",
          "secret_omission" => nil,
          "status" => "active"
        }
      ],
      "constraints" => [],
      "decisions" => [],
      "progress" => %{"completed" => [], "active" => [], "blocked" => [], "pending" => []},
      "critical_context" => [],
      "errors" => [],
      "artifact_refs" => [],
      "coverage" => %{"first_chat_seq" => first, "last_chat_seq" => last}
    }
  end
end
