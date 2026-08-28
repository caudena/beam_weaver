defmodule BeamWeaver.Compaction.Validator do
  @moduledoc false

  alias BeamWeaver.Compaction.{Canonical, InputEvent, Semantic}
  alias BeamWeaver.Core.Error

  @hash ~r/\A[0-9a-f]{64}\z/
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  @bounds Semantic.bounds()

  @spec validate_shape(Semantic.t()) :: {:ok, Semantic.t()} | {:error, Error.t()}
  def validate_shape(%Semantic{} = semantic) do
    with :ok <- exact(semantic.version, 1, "version"),
         :ok <- sourced_list(semantic.objective, @bounds.objective),
         :ok <- user_requests(semantic.user_requests),
         :ok <- sourced_list(semantic.constraints, @bounds.constraints),
         :ok <- decisions(semantic.decisions),
         :ok <- progress(semantic.progress),
         :ok <- sourced_list(semantic.critical_context, @bounds.critical_context),
         :ok <- errors(semantic.errors),
         :ok <- artifacts(semantic.artifact_refs),
         :ok <- coverage(semantic.coverage) do
      {:ok, semantic}
    end
  end

  @spec validate(Semantic.t(), [InputEvent.t()], keyword()) ::
          {:ok, Semantic.t()} | {:error, Error.t()}
  def validate(semantic, events, opts \\ [])

  def validate(%Semantic{} = semantic, events, opts) when is_list(events) do
    allowed_ids =
      events
      |> Enum.map(& &1.event_id)
      |> Kernel.++(Keyword.get(opts, :lineage_event_ids, []))
      |> MapSet.new()

    direct_user =
      events
      |> Enum.filter(&(&1.role == :user))
      |> Map.new(&{&1.event_id, &1.content || ""})

    expected_range = Keyword.fetch!(opts, :coverage)
    maximum_bytes = Keyword.get(opts, :maximum_bytes, 131_072)

    with {:ok, semantic} <- validate_shape(semantic),
         :ok <- exact_coverage(semantic.coverage, expected_range),
         :ok <- known_sources(semantic, allowed_ids),
         :ok <- source_backed_artifacts(semantic.artifact_refs, events, opts),
         :ok <- exact_excerpts(semantic.user_requests, direct_user),
         :ok <- unique_entries(semantic),
         {:ok, size} <- Canonical.encoded_size(Semantic.to_map(semantic)),
         true <- size <= maximum_bytes do
      {:ok, semantic}
    else
      false -> invalid("semantic output exceeds the byte limit")
      {:error, %Error{}} = error -> error
      {:error, _reason} -> invalid("semantic output is not canonical JSON")
    end
  end

  def validate(_semantic, _events, _opts), do: invalid("semantic validation input is invalid")

  @spec source_event_ids(Semantic.t()) :: [String.t()]
  def source_event_ids(%Semantic{} = semantic), do: source_ids(semantic)

  defp sourced_list(values, maximum) do
    list(values, maximum, fn value ->
      closed(value, ["text", "source_event_ids"], fn value ->
        with :ok <- text(fetch(value, "text"), @bounds.text_bytes),
             :ok <- event_ids(fetch(value, "source_event_ids"), 1) do
          :ok
        end
      end)
    end)
  end

  defp user_requests(values) do
    list(values, @bounds.user_requests, fn value ->
      closed(value, ["source_event_id", "exact_excerpt", "secret_omission", "status"], fn value ->
        excerpt = fetch(value, "exact_excerpt")
        omission = fetch(value, "secret_omission")

        with :ok <- uuid(fetch(value, "source_event_id")),
             :ok <- enum(fetch(value, "status"), ["active", "completed", "superseded"]),
             :ok <- excerpt_or_omission(excerpt, omission) do
          :ok
        end
      end)
    end)
  end

  defp decisions(values) do
    list(values, @bounds.decisions, fn value ->
      closed(value, ["text", "rationale", "source_event_ids"], fn value ->
        with :ok <- text(fetch(value, "text"), @bounds.text_bytes),
             :ok <- nullable_text(fetch(value, "rationale"), @bounds.text_bytes),
             :ok <- event_ids(fetch(value, "source_event_ids"), 1) do
          :ok
        end
      end)
    end)
  end

  defp progress(value) do
    closed(value, ["completed", "active", "blocked", "pending"], fn value ->
      with :ok <- progress_list(fetch(value, "completed"), @bounds.progress_completed),
           :ok <- progress_list(fetch(value, "active"), @bounds.progress_active),
           :ok <- progress_list(fetch(value, "blocked"), @bounds.progress_blocked),
           :ok <- progress_list(fetch(value, "pending"), @bounds.progress_pending) do
        :ok
      end
    end)
  end

  defp progress_list(values, maximum) do
    list(values, maximum, fn value ->
      closed(value, ["text", "source_event_ids", "verification_event_ids"], fn value ->
        with :ok <- text(fetch(value, "text"), @bounds.text_bytes),
             :ok <- event_ids(fetch(value, "source_event_ids"), 1),
             :ok <- event_ids(fetch(value, "verification_event_ids"), 0) do
          :ok
        end
      end)
    end)
  end

  defp errors(values) do
    list(values, @bounds.errors, fn value ->
      closed(value, ["message", "status", "source_event_ids"], fn value ->
        with :ok <- text(fetch(value, "message"), @bounds.text_bytes),
             :ok <- enum(fetch(value, "status"), ["open", "resolved"]),
             :ok <- event_ids(fetch(value, "source_event_ids"), 1) do
          :ok
        end
      end)
    end)
  end

  defp artifacts(values) do
    list(values, @bounds.artifact_refs, fn value ->
      closed(value, ["artifact_id", "purpose", "source_event_ids"], fn value ->
        with :ok <- uuid(fetch(value, "artifact_id")),
             :ok <- text(fetch(value, "purpose"), @bounds.text_bytes),
             :ok <- event_ids(fetch(value, "source_event_ids"), 1) do
          :ok
        end
      end)
    end)
  end

  defp coverage(value) do
    closed(value, ["first_chat_seq", "last_chat_seq"], fn value ->
      first = fetch(value, "first_chat_seq")
      last = fetch(value, "last_chat_seq")

      if is_integer(first) and first > 0 and is_integer(last) and last >= first,
        do: :ok,
        else: invalid("semantic coverage is invalid")
    end)
  end

  defp excerpt_or_omission(excerpt, nil), do: text(excerpt, @bounds.text_bytes)

  defp excerpt_or_omission(nil, omission) do
    closed(omission, ["class", "source_span_hash"], fn omission ->
      with :ok <- text(fetch(omission, "class"), 64),
           true <- hash?(fetch(omission, "source_span_hash")) do
        :ok
      else
        false -> invalid("secret omission hash is invalid")
        {:error, %Error{}} = error -> error
      end
    end)
  end

  defp excerpt_or_omission(_excerpt, _omission), do: invalid("request excerpt and omission are mutually exclusive")

  defp exact_coverage(value, {first, last}) do
    if fetch(value, "first_chat_seq") == first and fetch(value, "last_chat_seq") == last,
      do: :ok,
      else: invalid("semantic coverage does not match the source range")
  end

  defp known_sources(semantic, allowed_ids) do
    unknown = semantic |> source_ids() |> Enum.reject(&MapSet.member?(allowed_ids, &1))

    if unknown == [], do: :ok, else: invalid("semantic cites unknown source events", %{event_ids: unknown})
  end

  defp source_backed_artifacts(refs, events, opts) do
    sources =
      events
      |> Enum.reduce(%{}, fn event, acc ->
        Enum.reduce(event.artifact_ids, acc, fn artifact_id, values ->
          Map.update(values, artifact_id, MapSet.new([event.event_id]), &MapSet.put(&1, event.event_id))
        end)
      end)
      |> add_lineage_artifact_sources(Keyword.get(opts, :lineage_artifact_refs, []))

    invalid =
      Enum.flat_map(refs, fn ref ->
        artifact_id = fetch(ref, "artifact_id")
        cited = ref |> fetch("source_event_ids") |> MapSet.new()

        case Map.fetch(sources, artifact_id) do
          {:ok, allowed} -> if MapSet.subset?(cited, allowed), do: [], else: [artifact_id]
          :error -> [artifact_id]
        end
      end)

    if invalid == [],
      do: :ok,
      else: invalid("semantic cites artifacts without host source provenance", %{artifact_ids: invalid})
  end

  defp add_lineage_artifact_sources(sources, refs) when is_list(refs) do
    Enum.reduce(refs, sources, fn ref, acc ->
      artifact_id = fetch(ref, "artifact_id")
      event_ids = fetch(ref, "source_event_ids")

      if is_binary(artifact_id) and is_list(event_ids) do
        Map.update(acc, artifact_id, MapSet.new(event_ids), &MapSet.union(&1, MapSet.new(event_ids)))
      else
        acc
      end
    end)
  end

  defp add_lineage_artifact_sources(sources, _refs), do: sources

  defp exact_excerpts(requests, direct_user) do
    Enum.reduce_while(requests, :ok, fn request, :ok ->
      id = fetch(request, "source_event_id")
      excerpt = fetch(request, "exact_excerpt")

      valid? =
        case {Map.fetch(direct_user, id), excerpt} do
          {{:ok, content}, excerpt} when is_binary(excerpt) -> String.contains?(content, excerpt)
          {{:ok, _content}, nil} -> true
          _other -> false
        end

      if valid?, do: {:cont, :ok}, else: {:halt, invalid("user request excerpt is not source-backed")}
    end)
  end

  defp unique_entries(semantic) do
    duplicate? =
      semantic
      |> semantic_lists()
      |> Enum.any?(fn values ->
        keys = Enum.map(values, &Canonical.hash/1)
        length(keys) != length(Enum.uniq(keys))
      end)

    if duplicate?, do: invalid("semantic output contains duplicate entries"), else: :ok
  end

  defp semantic_lists(semantic) do
    [semantic.objective, semantic.user_requests, semantic.constraints, semantic.decisions] ++
      Map.values(semantic.progress) ++
      [semantic.critical_context, semantic.errors, semantic.artifact_refs]
  end

  defp source_ids(semantic) do
    semantic
    |> Semantic.to_map()
    |> collect_source_ids([])
    |> Enum.uniq()
  end

  defp collect_source_ids(%{} = value, acc) do
    acc =
      case fetch(value, "source_event_id") do
        id when is_binary(id) -> [id | acc]
        _other -> acc
      end

    acc =
      case fetch(value, "source_event_ids") do
        ids when is_list(ids) -> ids ++ acc
        _other -> acc
      end

    Enum.reduce(value, acc, fn {_key, nested}, nested_acc -> collect_source_ids(nested, nested_acc) end)
  end

  defp collect_source_ids(values, acc) when is_list(values),
    do: Enum.reduce(values, acc, &collect_source_ids/2)

  defp collect_source_ids(_value, acc), do: acc

  defp list(values, maximum, validator) when is_list(values) and length(values) <= maximum do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case validator.(value) do
        :ok -> {:cont, :ok}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp list(_values, _maximum, _validator), do: invalid("semantic collection is invalid or oversized")

  defp closed(%{} = value, keys, validator) do
    actual = value |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()

    if actual == Enum.sort(keys), do: validator.(value), else: invalid("semantic object has unexpected fields")
  end

  defp closed(_value, _keys, _validator), do: invalid("semantic object is invalid")

  defp event_ids(values, minimum) when is_list(values) do
    if length(values) >= minimum and length(values) <= @bounds.source_event_ids and
         Enum.uniq(values) == values and
         Enum.all?(values, &uuid?/1),
       do: :ok,
       else: invalid("semantic source event IDs are invalid")
  end

  defp event_ids(_values, _minimum), do: invalid("semantic source event IDs are invalid")
  defp uuid(value), do: if(uuid?(value), do: :ok, else: invalid("semantic UUID is invalid"))
  defp uuid?(value), do: is_binary(value) and value =~ @uuid
  defp hash?(value), do: is_binary(value) and value =~ @hash

  defp text(value, maximum) when is_binary(value) do
    if byte_size(value) >= 1 and byte_size(value) <= maximum and String.valid?(value),
      do: :ok,
      else: invalid("semantic text is invalid or oversized")
  end

  defp text(_value, _maximum), do: invalid("semantic text is invalid or oversized")
  defp nullable_text(nil, _maximum), do: :ok
  defp nullable_text(value, maximum), do: text(value, maximum)
  defp enum(value, allowed), do: if(value in allowed, do: :ok, else: invalid("semantic enum value is invalid"))
  defp exact(value, expected, _field) when value == expected, do: :ok
  defp exact(_value, _expected, field), do: invalid("semantic #{field} is invalid")

  defp fetch(map, key), do: Map.get(map, key, Map.get(map, String.to_atom(key)))
  defp invalid(message, details \\ %{}), do: {:error, Error.new(:invalid_compaction_semantic, message, details)}
end
