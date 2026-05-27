defmodule BeamWeaver.Checkpoint.FakeSQL do
  @moduledoc false

  def start_link do
    Agent.start_link(fn -> %{checkpoints: %{}, writes: %{}} end)
  end

  def query(repo, sql, params) do
    cond do
      String.contains?(sql, "INSERT INTO beam_weaver_checkpoints") and
          String.contains?(sql, "SELECT $2") ->
        copy_checkpoints(repo, params)

      String.contains?(sql, "INSERT INTO beam_weaver_checkpoint_writes") and
          String.contains?(sql, "SELECT $2") ->
        copy_writes(repo, params)

      String.contains?(sql, "INSERT INTO beam_weaver_checkpoints") ->
        insert_checkpoint(repo, params)

      String.contains?(sql, "INSERT INTO beam_weaver_checkpoint_writes") ->
        insert_write(repo, params)

      String.contains?(sql, "SELECT checkpoint_id") ->
        latest_checkpoint_id(repo, params)

      String.contains?(sql, "SELECT task_id, channel, value, task_path") ->
        select_pending_writes(repo, params)

      String.contains?(sql, "SELECT thread_id, checkpoint_ns, checkpoint_id") and
          String.contains?(sql, "metadata->>'run_id'") ->
        select_checkpoints_by_run_id(repo, params)

      String.contains?(sql, "SELECT thread_id, checkpoint_ns, checkpoint_id") and
          not String.contains?(sql, "parent_checkpoint_id") ->
        select_checkpoint_keys(repo, sql, params)

      String.contains?(sql, "SELECT thread_id, checkpoint_ns, checkpoint_id") ->
        select_checkpoint_rows(repo, sql, params)

      String.contains?(sql, "DELETE FROM beam_weaver_checkpoint_writes") ->
        delete_writes(repo, params)

      String.contains?(sql, "DELETE FROM beam_weaver_checkpoints") ->
        delete_checkpoints(repo, params)

      true ->
        {:ok, %{rows: []}}
    end
  end

  defp insert_checkpoint(repo, [
         thread_id,
         namespace,
         checkpoint_id,
         parent_id,
         checkpoint,
         metadata
       ]) do
    Agent.update(repo, fn state ->
      key = {thread_id, namespace, checkpoint_id}
      checkpoints = Map.put(state.checkpoints, key, {parent_id, checkpoint, metadata})
      %{state | checkpoints: checkpoints}
    end)

    {:ok, %{rows: []}}
  end

  defp insert_write(repo, [
         thread_id,
         namespace,
         checkpoint_id,
         task_id,
         index,
         channel,
         value,
         task_path
       ]) do
    Agent.update(repo, fn state ->
      key = {thread_id, namespace, checkpoint_id, task_id, index}
      writes = Map.put(state.writes, key, {channel, value, task_path})
      %{state | writes: writes}
    end)

    {:ok, %{rows: []}}
  end

  defp latest_checkpoint_id(repo, [thread_id, namespace]) do
    latest =
      Agent.get(repo, fn state ->
        state.checkpoints
        |> Map.keys()
        |> Enum.flat_map(fn
          {^thread_id, ^namespace, checkpoint_id} -> [checkpoint_id]
          _other -> []
        end)
        |> Enum.sort(:desc)
        |> List.first()
      end)

    {:ok, %{rows: if(latest, do: [[latest]], else: [])}}
  end

  defp select_checkpoint_rows(repo, sql, params) do
    if length(params) == 3 and String.contains?(sql, "checkpoint_id = $3") do
      [thread_id, namespace, checkpoint_id] = params

      rows =
        Agent.get(repo, fn state ->
          case Map.fetch(state.checkpoints, {thread_id, namespace, checkpoint_id}) do
            {:ok, {parent_id, checkpoint, metadata}} ->
              [[thread_id, namespace, checkpoint_id, parent_id, checkpoint, metadata]]

            :error ->
              []
          end
        end)

      {:ok, %{rows: rows}}
    else
      criteria = list_criteria(sql, params)

      rows =
        repo
        |> all_checkpoint_rows()
        |> Enum.filter(&matches_criteria?(&1, criteria))
        |> Enum.sort_by(
          fn [
               _thread_id,
               _namespace,
               checkpoint_id,
               _parent,
               _checkpoint,
               _metadata
             ] ->
            checkpoint_id
          end,
          :desc
        )
        |> maybe_limit(sql)

      {:ok, %{rows: rows}}
    end
  end

  defp select_checkpoint_keys(repo, sql, params) do
    criteria = list_criteria(sql, params)

    rows =
      repo
      |> all_checkpoint_rows()
      |> Enum.filter(&matches_criteria?(&1, criteria))
      |> Enum.map(fn [thread_id, namespace, checkpoint_id, _parent, _checkpoint, _metadata] ->
        [thread_id, namespace, checkpoint_id]
      end)
      |> Enum.sort_by(fn [_thread_id, _namespace, checkpoint_id] -> checkpoint_id end, :desc)

    {:ok, %{rows: rows}}
  end

  defp select_checkpoints_by_run_id(repo, [run_ids]) do
    run_ids = MapSet.new(run_ids)

    rows =
      repo
      |> all_checkpoint_rows()
      |> Enum.flat_map(fn [thread_id, namespace, checkpoint_id, _parent, _checkpoint, metadata] ->
        if MapSet.member?(run_ids, Map.get(metadata, "run_id")) do
          [[thread_id, namespace, checkpoint_id]]
        else
          []
        end
      end)

    {:ok, %{rows: rows}}
  end

  defp select_pending_writes(repo, [thread_id, namespace, checkpoint_id]) do
    rows =
      Agent.get(repo, fn state ->
        state.writes
        |> Enum.flat_map(fn
          {{^thread_id, ^namespace, ^checkpoint_id, task_id, index}, {channel, value, path}} ->
            [{task_id, index, channel, value, path || ""}]

          _other ->
            []
        end)
        |> Enum.sort_by(fn {task_id, index, _channel, _value, _path} -> {task_id, index} end)
        |> Enum.map(fn {task_id, _index, channel, value, path} ->
          [task_id, channel, value, path]
        end)
      end)

    {:ok, %{rows: rows}}
  end

  defp copy_checkpoints(repo, [source_thread_id, target_thread_id]) do
    Agent.update(repo, fn state ->
      copied =
        state.checkpoints
        |> Enum.flat_map(fn
          {{^source_thread_id, namespace, checkpoint_id}, record} ->
            [{{target_thread_id, namespace, checkpoint_id}, record}]

          _other ->
            []
        end)
        |> Map.new()

      %{state | checkpoints: Map.merge(state.checkpoints, copied)}
    end)

    {:ok, %{rows: []}}
  end

  defp copy_writes(repo, [source_thread_id, target_thread_id]) do
    Agent.update(repo, fn state ->
      copied =
        state.writes
        |> Enum.flat_map(fn
          {{^source_thread_id, namespace, checkpoint_id, task_id, index}, write} ->
            [{{target_thread_id, namespace, checkpoint_id, task_id, index}, write}]

          _other ->
            []
        end)
        |> Map.new()

      %{state | writes: Map.merge(state.writes, copied)}
    end)

    {:ok, %{rows: []}}
  end

  defp delete_writes(repo, [thread_id]) do
    Agent.update(repo, fn state ->
      writes =
        Map.reject(state.writes, fn
          {{^thread_id, _namespace, _checkpoint_id, _task_id, _index}, _write} -> true
          _other -> false
        end)

      %{state | writes: writes}
    end)

    {:ok, %{rows: []}}
  end

  defp delete_writes(repo, [thread_id, namespace]) do
    Agent.update(repo, fn state ->
      writes =
        Map.reject(state.writes, fn
          {{^thread_id, ^namespace, _checkpoint_id, _task_id, _index}, _write} -> true
          _other -> false
        end)

      %{state | writes: writes}
    end)

    {:ok, %{rows: []}}
  end

  defp delete_writes(repo, [thread_id, namespace, checkpoint_id]) do
    Agent.update(repo, fn state ->
      writes =
        Map.reject(state.writes, fn
          {{^thread_id, ^namespace, ^checkpoint_id, _task_id, _index}, _write} -> true
          _other -> false
        end)

      %{state | writes: writes}
    end)

    {:ok, %{rows: []}}
  end

  defp delete_checkpoints(repo, [thread_id]) do
    Agent.update(repo, fn state ->
      checkpoints =
        Map.reject(state.checkpoints, fn
          {{^thread_id, _namespace, _checkpoint_id}, _record} -> true
          _other -> false
        end)

      %{state | checkpoints: checkpoints}
    end)

    {:ok, %{rows: []}}
  end

  defp delete_checkpoints(repo, [thread_id, namespace]) do
    Agent.update(repo, fn state ->
      checkpoints =
        Map.reject(state.checkpoints, fn
          {{^thread_id, ^namespace, _checkpoint_id}, _record} -> true
          _other -> false
        end)

      %{state | checkpoints: checkpoints}
    end)

    {:ok, %{rows: []}}
  end

  defp delete_checkpoints(repo, [thread_id, namespace, checkpoint_id]) do
    Agent.update(repo, fn state ->
      checkpoints = Map.delete(state.checkpoints, {thread_id, namespace, checkpoint_id})
      %{state | checkpoints: checkpoints}
    end)

    {:ok, %{rows: []}}
  end

  defp all_checkpoint_rows(repo) do
    Agent.get(repo, fn state ->
      Enum.map(state.checkpoints, fn {{thread_id, namespace, checkpoint_id},
                                      {parent, checkpoint, metadata}} ->
        [thread_id, namespace, checkpoint_id, parent, checkpoint, metadata]
      end)
    end)
  end

  defp list_criteria(sql, params) do
    {criteria, index} = {%{}, 0}

    {criteria, index} =
      if String.contains?(sql, "thread_id = $") do
        {Map.put(criteria, :thread_id, Enum.at(params, index)), index + 1}
      else
        {criteria, index}
      end

    {criteria, index} =
      if String.contains?(sql, "checkpoint_ns = $") do
        {Map.put(criteria, :namespace, Enum.at(params, index)), index + 1}
      else
        {criteria, index}
      end

    {criteria, index} =
      if String.contains?(sql, "checkpoint_id < $") do
        {Map.put(criteria, :before, Enum.at(params, index)), index + 1}
      else
        {criteria, index}
      end

    if String.contains?(sql, "metadata @> $") do
      Map.put(criteria, :filter, Enum.at(params, index))
    else
      criteria
    end
  end

  defp matches_criteria?(
         [thread_id, namespace, checkpoint_id, _parent, _checkpoint, metadata],
         criteria
       ) do
    Enum.all?(criteria, fn
      {:thread_id, value} ->
        thread_id == value

      {:namespace, value} ->
        namespace == value

      {:before, value} ->
        checkpoint_id < value

      {:filter, filter} ->
        Enum.all?(filter, fn {key, value} -> Map.get(metadata, key) == value end)
    end)
  end

  defp maybe_limit(rows, sql) do
    case Regex.run(~r/LIMIT\s+(\d+)/, sql) do
      [_match, limit] -> Enum.take(rows, String.to_integer(limit))
      nil -> rows
    end
  end
end
