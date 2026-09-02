defmodule BeamWeaver.Compaction.Engine do
  @moduledoc false

  alias BeamWeaver.Compaction.{
    Canonical,
    Checkpoint,
    CutPoint,
    InputEvent,
    Request,
    Result,
    Semantic,
    State,
    ToolProjection,
    Validator
  }

  alias BeamWeaver.ContextBudget
  alias BeamWeaver.Core.Error

  @prompt_reserve_tokens 4_096

  @spec compact(map(), Request.t()) :: {:ok, Result.t()} | {:error, Error.t()}
  def compact(_agent_state, %Request{} = request) do
    with {:ok, request} <- Request.new(request),
         :ok <- portable(request),
         {:ok, before} <- initial_budget(request),
         {:ok, request} <- rebase_accounting(request, before),
         :ok <- eligible(request, before),
         {:ok, prefix, tail, projected, manifest, projected_budget} <- project(request, before),
         {:continue, prefix} <-
           maybe_pruned(request, before, projected_budget, prefix, tail, projected, manifest),
         {:ok, semantic, usage} <- summarize(request, before, prefix),
         {:ok, final_bytes, final_categories} <- render(request, semantic, tail),
         {:ok, after_budget} <- budget(request, final_bytes, final_categories),
         :ok <- effective(request, before, after_budget),
         checkpoint <- checkpoint(request, :portable, semantic, tail, manifest, before, after_budget, usage) do
      {:ok, result(:compacted, checkpoint, request.events, tail, before, after_budget, usage)}
    else
      {:skip, reason, before} -> {:ok, skipped(request, before, reason)}
      {:pruned, %Result{} = result} -> {:ok, result}
      {:continue, []} -> {:error, Error.new(:current_input_item_too_large, "no safe history prefix can be compacted")}
      {:error, %Error{}} = error -> error
      {:error, reason} -> {:error, Error.new(:compaction_failed, "compaction failed", %{reason: inspect(reason)})}
    end
  end

  def compact(_agent_state, request) do
    with {:ok, request} <- Request.new(request), do: compact(%{}, request)
  end

  defp portable(%Request{policy: %{mode: :portable}}), do: :ok

  defp portable(%Request{}) do
    {:error, Error.new(:native_compaction_unsupported, "provider-native compaction is not implemented by this engine")}
  end

  defp eligible(request, before) do
    suppression = State.auto_suppression(request.anti_thrash, request.policy)

    cond do
      request.trigger == :auto and not request.structural_pressure and suppression != nil ->
        {:skip, suppression, before}

      request.trigger == :auto and not request.structural_pressure and
          before.estimated_tokens < before.trigger_tokens ->
        {:skip, :below_trigger, before}

      true ->
        :ok
    end
  end

  defp project(request, before) do
    tail_budget =
      before.effective_input_limit
      |> Kernel.*(request.policy.recent_tail_ratio)
      |> floor()
      |> clamp(request.policy.recent_tail_min_tokens, request.policy.recent_tail_max_tokens)

    {prefix, tail} = CutPoint.split(request.events, tail_budget, request.active_input_event_ids)
    protected = MapSet.new(tail, & &1.event_id)

    with {:ok, projected_prefix, manifest} <- ToolProjection.project(prefix, protected),
         projected <- projected_prefix ++ tail,
         {:ok, bytes, categories} <- render(request, request.previous_semantic, projected),
         {:ok, projected_budget} <- budget(request, bytes, categories) do
      {:ok, projected_prefix, tail, projected, manifest, projected_budget}
    end
  end

  defp maybe_pruned(request, before, after_budget, prefix, _tail, projected, manifest) do
    reclaimed = before.estimated_tokens - after_budget.estimated_tokens

    released? =
      after_budget.estimated_tokens <=
        floor(before.effective_input_limit * request.policy.prune_release_ratio)

    if manifest != [] and released? and reclaimed >= request.policy.minimum_prune_reclaim_tokens do
      checkpoint =
        checkpoint(request, :pruned, nil, projected, manifest, before, after_budget, nil)

      {:pruned, result(:pruned, checkpoint, request.events, projected, before, after_budget, nil)}
    else
      {:continue, prefix}
    end
  end

  defp summarize(request, before, prefix) do
    output_tokens = summary_output_tokens(request, before)
    input_budget = before.effective_input_limit - output_tokens - @prompt_reserve_tokens

    with true <- input_budget > 0,
         {:ok, chunks} <- chunks(prefix, input_budget, request.policy.maximum_hierarchical_summary_calls) do
      Enum.reduce_while(chunks, {:ok, request.previous_semantic, [], [], request.policy.maximum_schema_repairs}, fn
        chunk, {:ok, previous, processed_reversed, usages, repairs_left} ->
          processed_reversed = Enum.reverse(chunk, processed_reversed)
          processed = Enum.reverse(processed_reversed)
          coverage = {List.first(processed).chat_seq, List.last(processed).chat_seq}
          payload = summary_payload(request, previous, chunk, coverage, output_tokens)

          case summarize_chunk(request, payload, processed, coverage, repairs_left) do
            {:ok, semantic, usage, repairs_left} ->
              {:cont, {:ok, semantic, processed_reversed, [usage | usages], repairs_left}}

            {:error, %Error{}} = error ->
              {:halt, error}
          end
      end)
      |> case do
        {:ok, %Semantic{} = semantic, _processed, usages, _repairs_left} ->
          {:ok, semantic, usages |> Enum.reverse() |> Enum.reject(&is_nil/1)}

        {:ok, nil, _processed, _usages, _repairs_left} ->
          {:error, Error.new(:nothing_to_compact, "no source events were selected")}

        error ->
          error
      end
    else
      false -> {:error, Error.new(:compaction_input_too_large, "compactor prompt and output allowance do not fit")}
      {:error, %Error{}} = error -> error
    end
  end

  defp summarize_chunk(request, payload, processed, coverage, repairs_left) do
    case call_summarizer(request, payload) do
      {:ok, output, usage} ->
        case validate_output(request, output, processed, coverage) do
          {:ok, semantic} ->
            {:ok, semantic, usage, repairs_left}

          {:error, %Error{} = error} when repairs_left > 0 ->
            repair_payload = Map.put(payload, :repair, %{invalid_output: output, error: error_map(error)})

            with {:ok, repaired, repair_usage} <- call_summarizer(request, repair_payload),
                 {:ok, semantic} <-
                   validate_output(request, repaired, processed, coverage) do
              usage = [usage, repair_usage] |> Enum.reject(&is_nil/1)
              {:ok, semantic, usage, repairs_left - 1}
            end

          {:error, %Error{}} = error ->
            error
        end

      {:error, %Error{}} = error ->
        error
    end
  end

  defp call_summarizer(request, payload) do
    case request.summarize.(payload) do
      {:ok, output, usage} ->
        {:ok, output, usage}

      {:ok, output} ->
        {:ok, output, nil}

      {:error, %Error{}} = error ->
        error

      {:error, reason} ->
        {:error, Error.new(:compaction_provider_error, "compaction model failed", %{reason: inspect(reason)})}

      other ->
        {:error,
         Error.new(:compaction_provider_error, "compaction model returned an invalid result", %{result: inspect(other)})}
    end
  rescue
    error ->
      {:error, Error.new(:compaction_provider_error, "compaction model raised", %{exception: Exception.message(error)})}
  end

  defp validate_output(request, output, events, coverage) do
    lineage_event_ids =
      case request.previous_semantic do
        %Semantic{} = semantic -> Validator.source_event_ids(semantic)
        nil -> []
      end

    with {:ok, decoded} <- decode_output(output),
         {:ok, semantic} <- Semantic.new(decoded),
         {:ok, semantic} <-
           Validator.validate(semantic, events,
             coverage: coverage,
             maximum_bytes: request.policy.semantic_max_bytes,
             lineage_event_ids: lineage_event_ids,
             lineage_artifact_refs:
               case request.previous_semantic do
                 %Semantic{} = previous -> previous.artifact_refs
                 nil -> []
               end
           ) do
      {:ok, semantic}
    end
  end

  defp decode_output(%{} = output), do: {:ok, output}

  defp decode_output(output) when is_binary(output) do
    case BeamWeaver.JSON.decode(output) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, reason} ->
        {:error, Error.new(:invalid_compaction_semantic, "compaction output is not JSON", %{reason: inspect(reason)})}
    end
  end

  defp decode_output(_output),
    do: {:error, Error.new(:invalid_compaction_semantic, "compaction output must be JSON data")}

  defp summary_payload(request, previous, events, coverage, output_tokens) do
    %{
      schema_version: "compaction_input_v1",
      checkpoint_id: request.request_id,
      covered_range: %{first_chat_seq: elem(coverage, 0), last_chat_seq: elem(coverage, 1)},
      previous_semantic: previous && Semantic.to_map(previous),
      events: Enum.map(events, &InputEvent.to_map/1),
      focus: request.focus,
      maximum_output_tokens: output_tokens
    }
  end

  defp chunks(events, maximum_tokens, maximum_chunks) do
    Enum.reduce_while(events, {:ok, [], [], 0}, fn event, {:ok, chunks, current, tokens} ->
      cost = InputEvent.estimated_tokens(event)

      cond do
        cost > maximum_tokens ->
          {:halt,
           {:error, Error.new(:compaction_input_too_large, "one source event exceeds the compactor input limit")}}

        tokens + cost <= maximum_tokens ->
          {:cont, {:ok, chunks, [event | current], tokens + cost}}

        length(chunks) + 1 >= maximum_chunks ->
          {:halt, {:error, Error.new(:compaction_input_too_large, "source history needs too many summary calls")}}

        true ->
          {:cont, {:ok, [Enum.reverse(current) | chunks], [event], cost}}
      end
    end)
    |> case do
      {:ok, _chunks, [], _tokens} -> {:ok, []}
      {:ok, chunks, current, _tokens} -> {:ok, Enum.reverse([Enum.reverse(current) | chunks])}
      error -> error
    end
  end

  defp effective(request, before, after_budget) do
    reclaimed = before.estimated_tokens - after_budget.estimated_tokens
    ratio = if before.estimated_tokens == 0, do: 0.0, else: reclaimed / before.estimated_tokens
    target = floor(before.effective_input_limit * request.policy.post_compaction_target_ratio)

    if after_budget.estimated_tokens <= target and
         reclaimed >= request.policy.minimum_total_reclaim_tokens and
         ratio >= request.policy.minimum_total_reclaim_ratio do
      :ok
    else
      {:error,
       Error.new(:ineffective_compaction, "compaction did not reclaim enough context", %{
         tokens_before: before.estimated_tokens,
         tokens_after: after_budget.estimated_tokens
       })}
    end
  end

  defp checkpoint(
         request,
         representation,
         semantic,
         retained,
         manifest,
         before,
         after_budget,
         usage
       ) do
    first = List.first(request.events)
    last = List.last(request.events)
    summary_last = summary_last(request.events, retained, request.previous_semantic)
    semantic_hash = semantic && Canonical.hash(Semantic.to_map(semantic))

    %Checkpoint{
      checkpoint_id: request.request_id,
      parent_checkpoint_id: request.parent_checkpoint_id,
      thread_id: request.thread_id,
      run_id: request.run_id,
      root_turn_id: request.root_turn_id,
      run_agent_id: request.run_agent_id,
      checkpoint_namespace: request.checkpoint_namespace,
      trigger: request.trigger,
      representation: representation,
      source_chat_seq_range: {first.chat_seq, last.chat_seq},
      summary_coverage_last_chat_seq: summary_last && summary_last.chat_seq,
      context_chat_seq_high_watermark: last.chat_seq,
      retained_from_chat_seq: retained |> List.first() |> then(&(&1 && &1.chat_seq)),
      source_lane_event_ordinal_range: {first.lane_event_ordinal, last.lane_event_ordinal},
      summary_coverage_last_lane_event_ordinal: summary_last && summary_last.lane_event_ordinal,
      context_lane_event_ordinal_high_watermark: last.lane_event_ordinal,
      semantic: semantic,
      semantic_hash: semantic_hash,
      rehydration_state: request.rehydration_state,
      rehydration_state_hash: request.rehydration_state.hash,
      provider_connection_id: request.provider_connection_id,
      destination_identity_hash: request.destination_identity_hash,
      accounting_method: before.method,
      accounting_version: before.version,
      accounting_profile_hash: before.profile_hash,
      category_bytes: before.category_bytes,
      category_tokens: before.categories,
      tokens_before: before.estimated_tokens,
      tokens_after: after_budget.estimated_tokens,
      tokens_reclaimed: before.estimated_tokens - after_budget.estimated_tokens,
      retained_event_ids: Enum.map(retained, & &1.event_id),
      projection_manifest: manifest,
      provider_usage: usage,
      validation_status: :valid,
      created_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end

  defp summary_last(events, retained, previous) do
    retained_ids = MapSet.new(retained, & &1.event_id)

    Enum.find(Enum.reverse(events), fn event -> not MapSet.member?(retained_ids, event.event_id) end) ||
      if(previous,
        do: %{
          chat_seq: previous.coverage["last_chat_seq"] || previous.coverage[:last_chat_seq],
          lane_event_ordinal: nil
        }
      )
  end

  defp result(status, checkpoint, source, retained, before, after_budget, usage) do
    %Result{
      status: status,
      compaction_checkpoint: checkpoint,
      tokens_before: before.estimated_tokens,
      tokens_after: after_budget.estimated_tokens,
      tokens_reclaimed: before.estimated_tokens - after_budget.estimated_tokens,
      source_event_count: length(source),
      retained_event_count: length(retained),
      retained_events: retained,
      artifact_ids: source |> Enum.flat_map(& &1.artifact_ids) |> Enum.uniq(),
      provider_usage: usage
    }
  end

  defp skipped(request, before, reason) do
    %Result{
      status: :skipped,
      compaction_checkpoint: nil,
      tokens_before: before.estimated_tokens,
      tokens_after: before.estimated_tokens,
      tokens_reclaimed: 0,
      source_event_count: length(request.events),
      retained_event_count: length(request.events),
      retained_events: request.events,
      artifact_ids: [],
      provider_usage: %{suppression: reason}
    }
  end

  defp render(request, semantic, events) do
    case request.render.(semantic, events) do
      {:ok, bytes} when is_binary(bytes) ->
        {:ok, bytes, %{}}

      {:ok, bytes, categories} when is_binary(bytes) and is_map(categories) ->
        {:ok, bytes, categories}

      {:error, %Error{}} = error ->
        error

      {:error, reason} ->
        {:error, Error.new(:compaction_render_error, "context rendering failed", %{reason: inspect(reason)})}

      other ->
        {:error,
         Error.new(:compaction_render_error, "context renderer returned an invalid result", %{result: inspect(other)})}
    end
  rescue
    error ->
      {:error, Error.new(:compaction_render_error, "context renderer raised", %{exception: Exception.message(error)})}
  end

  defp initial_budget(request) do
    accounting = request.accounting

    budget(
      request,
      request.rendered_request,
      nil,
      value(accounting, :reported_input_tokens, 0),
      true
    )
  end

  defp budget(request, bytes, categories), do: budget(request, bytes, categories, 0, false)

  defp budget(request, bytes, categories, reported_input_tokens, use_baseline?) do
    accounting = request.accounting

    ContextBudget.new(request.model_profile, bytes,
      trigger_ratio: request.policy.trigger_ratio,
      requested_max_output_tokens: request.requested_max_output_tokens,
      categories: categories || value(accounting, :category_bytes, %{}),
      accounting_method: value(accounting, :method, :conservative_utf8),
      reported_input_tokens: reported_input_tokens,
      reported_usage_baseline: if(use_baseline?, do: value(accounting, :reported_usage_baseline), else: nil),
      component_descriptors: if(use_baseline?, do: value(accounting, :component_descriptors), else: nil),
      profile_hash: value(accounting, :profile_hash)
    )
  end

  defp rebase_accounting(request, budget) do
    with {:ok, state} <-
           State.rebase_accounting(request.anti_thrash, %{
             method: budget.method,
             version: budget.version,
             profile_hash: budget.profile_hash
           }) do
      {:ok, %{request | anti_thrash: state}}
    end
  end

  defp summary_output_tokens(request, before) do
    requested = floor(before.effective_input_limit * request.policy.summary_output_ratio)
    maximum = profile_value(request.model_profile, :max_output_tokens) || request.policy.summary_output_max_tokens

    requested
    |> clamp(request.policy.summary_output_min_tokens, request.policy.summary_output_max_tokens)
    |> min(maximum)
  end

  defp profile_value(%{} = profile, key), do: Map.get(profile, key, Map.get(profile, Atom.to_string(key)))
  defp profile_value(_profile, _key), do: nil

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp clamp(value, minimum, maximum), do: value |> max(minimum) |> min(maximum)
  defp error_map(error), do: %{type: error.type, message: error.message, details: error.details}
end
