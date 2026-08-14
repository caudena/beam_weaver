defmodule BeamWeaver.Todo do
  @moduledoc """
  Immutable, dependency-aware Todo revisions.

  `new/2` creates revision one. `revise/3` accepts a complete next item set,
  verifies the expected revision and hash, and requires typed evidence for each
  state transition. Todo IDs and definitions remain stable across revisions.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Todo.Item

  @schema_version 1
  @max_items 128
  @max_edges 512
  @terminal [:completed, :cancelled]
  @statuses Item.statuses()
  @item_keys MapSet.new([:id, :content, :dependencies, :status, :owner, :assignment_id, :blocker, :evidence])
  @evidence_kinds [:assignment, :blocker, :blocker_resolved, :completion, :cancellation]

  @enforce_keys [:id, :revision, :items, :active_item_ids, :hash]
  defstruct schema_version: @schema_version,
            id: nil,
            revision: nil,
            previous_hash: nil,
            items: [],
            active_item_ids: [],
            hash: nil

  @type t :: %__MODULE__{
          schema_version: 1,
          id: String.t(),
          revision: pos_integer(),
          previous_hash: String.t() | nil,
          items: [Item.t()],
          active_item_ids: [String.t()],
          hash: String.t()
        }

  @doc "Creates the first immutable revision for `id`."
  @spec new(String.t(), [Item.t() | map()]) :: {:ok, t()} | {:error, Error.t()}
  def new(id, items) do
    with :ok <- nonempty(id, :id),
         {:ok, items} <- normalize_items(items),
         :ok <- validate_items(items) do
      {:ok, build(id, 1, nil, items)}
    end
  end

  @doc """
  Creates the next revision.

  Options must contain `:expected_revision` and `:expected_hash`. Existing item
  definitions and ordering cannot change; new items may be appended.
  """
  @spec revise(t(), [Item.t() | map()], keyword()) :: {:ok, t()} | {:error, Error.t()}
  def revise(%__MODULE__{} = current, items, opts) when is_list(opts) do
    with :ok <- expected(current, opts),
         {:ok, items} <- normalize_items(items),
         :ok <- validate_items(items),
         :ok <- validate_revision(current.items, items) do
      {:ok, build(current.id, current.revision + 1, current.hash, items)}
    end
  end

  def revise(_current, _items, _opts), do: invalid(:invalid_todo, "invalid Todo revision")

  @doc "Revalidates a Todo revision, including its deterministic hash."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{schema_version: @schema_version} = todo) do
    with :ok <- nonempty(todo.id, :id),
         true <- is_integer(todo.revision) and todo.revision > 0,
         {:ok, normalized} <- normalize_items(todo.items),
         true <- normalized == todo.items,
         :ok <- validate_items(normalized),
         true <- todo.active_item_ids == active_ids(todo.items),
         true <- todo.hash == digest(todo_payload(todo)) do
      :ok
    else
      false -> invalid(:invalid_todo, "Todo revision fields or hash do not match")
      {:error, %Error{}} = error -> error
    end
  end

  def validate(_todo), do: invalid(:invalid_todo, "invalid Todo revision")

  defp expected(current, opts) do
    if Keyword.get(opts, :expected_revision) == current.revision and
         Keyword.get(opts, :expected_hash) == current.hash do
      :ok
    else
      invalid(:stale_todo, "Todo revision or hash is stale")
    end
  end

  defp normalize_items(items) when is_list(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case normalize_item(item) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp normalize_items(_items), do: invalid(:invalid_todo, "Todo items must be a list")

  defp normalize_item(%Item{} = item), do: normalize_item(Map.from_struct(item))

  defp normalize_item(%{} = attrs) do
    with {:ok, attrs} <- atom_keys(attrs),
         true <- MapSet.subset?(MapSet.new(Map.keys(attrs)), @item_keys),
         :ok <- nonempty(attrs[:id], :item_id),
         :ok <- nonempty(attrs[:content], :content),
         {:ok, dependencies} <- string_list(attrs[:dependencies] || [], :dependencies),
         {:ok, status} <- status(attrs[:status] || :pending),
         :ok <- optional_string(attrs[:owner], :owner),
         :ok <- optional_string(attrs[:assignment_id], :assignment_id),
         :ok <- blocker(status, attrs[:blocker]),
         {:ok, evidence} <- evidence(attrs[:evidence] || []) do
      {:ok,
       %Item{
         id: attrs.id,
         content: attrs.content,
         dependencies: dependencies,
         status: status,
         owner: attrs[:owner],
         assignment_id: attrs[:assignment_id],
         blocker: attrs[:blocker],
         evidence: evidence
       }}
    else
      false -> invalid(:invalid_todo_item, "Todo item contains unknown fields")
      {:error, %Error{}} = error -> error
    end
  end

  defp normalize_item(_item), do: invalid(:invalid_todo_item, "Todo item must be a map")

  defp validate_items(items) when length(items) <= @max_items do
    ids = Enum.map(items, & &1.id)
    edge_count = Enum.reduce(items, 0, &(length(&1.dependencies) + &2))

    with true <- length(ids) == MapSet.size(MapSet.new(ids)),
         true <- edge_count <= @max_edges,
         :ok <- validate_state_evidence(items),
         :ok <- validate_edges(items, MapSet.new(ids)),
         :ok <- validate_dag(items) do
      :ok
    else
      false -> invalid(:invalid_todo, "Todo IDs must be unique and dependency bounds must hold")
      {:error, %Error{}} = error -> error
    end
  end

  defp validate_items(_items), do: invalid(:invalid_todo, "Todo exceeds the #{@max_items}-item bound")

  defp validate_state_evidence(items) do
    if Enum.all?(items, &valid_state_evidence?/1) do
      :ok
    else
      invalid(:invalid_todo_item, "Todo status and assignment must carry matching evidence")
    end
  end

  defp valid_state_evidence?(item) do
    assignment_valid? =
      (is_nil(item.owner) and is_nil(item.assignment_id)) or
        (is_binary(item.owner) and is_binary(item.assignment_id) and has_evidence?(item, :assignment))

    status_valid? =
      case item.status do
        :pending -> true
        :in_progress -> is_binary(item.owner) and is_binary(item.assignment_id)
        :blocked -> has_evidence?(item, :blocker)
        :completed -> has_evidence?(item, :completion)
        :cancelled -> has_evidence?(item, :cancellation)
      end

    assignment_valid? and status_valid?
  end

  defp validate_edges(items, ids) do
    if Enum.all?(items, fn item ->
         length(item.dependencies) == MapSet.size(MapSet.new(item.dependencies)) and
           Enum.all?(item.dependencies, &(&1 != item.id and MapSet.member?(ids, &1)))
       end) do
      :ok
    else
      invalid(:invalid_todo_dependency, "Todo dependencies must be unique, known, and not self-referential")
    end
  end

  defp validate_dag(items) do
    dependencies = Map.new(items, &{&1.id, &1.dependencies})

    Enum.reduce_while(Map.keys(dependencies), {:ok, %{}}, fn id, {:ok, done} ->
      case visit(id, dependencies, done, %{}) do
        {:ok, done} -> {:cont, {:ok, done}}
        :cycle -> {:halt, :cycle}
      end
    end)
    |> case do
      {:ok, _done} -> :ok
      :cycle -> invalid(:todo_cycle, "Todo dependencies must form a DAG")
    end
  end

  @spec visit(
          String.t(),
          %{String.t() => [String.t()]},
          %{optional(String.t()) => true},
          %{optional(String.t()) => true}
        ) :: {:ok, %{optional(String.t()) => true}} | :cycle
  defp visit(id, dependencies, done, visiting) do
    cond do
      Map.has_key?(done, id) -> {:ok, done}
      Map.has_key?(visiting, id) -> :cycle
      true -> visit_dependencies(id, dependencies, done, Map.put(visiting, id, true))
    end
  end

  @spec visit_dependencies(
          String.t(),
          %{String.t() => [String.t()]},
          %{optional(String.t()) => true},
          %{optional(String.t()) => true}
        ) :: {:ok, %{optional(String.t()) => true}} | :cycle
  defp visit_dependencies(id, dependencies, done, visiting) do
    Enum.reduce_while(Map.fetch!(dependencies, id), {:ok, done}, fn dependency, {:ok, done} ->
      case visit(dependency, dependencies, done, visiting) do
        {:ok, done} -> {:cont, {:ok, done}}
        :cycle -> {:halt, :cycle}
      end
    end)
    |> case do
      {:ok, done} -> {:ok, Map.put(done, id, true)}
      :cycle -> :cycle
    end
  end

  defp validate_revision(previous, next) do
    previous_by_id = Map.new(previous, &{&1.id, &1})

    with true <- Enum.take(next, length(previous)) |> Enum.map(& &1.id) == Enum.map(previous, & &1.id),
         true <- length(next) >= length(previous) do
      Enum.reduce_while(next, :ok, fn item, :ok ->
        case previous_by_id[item.id] do
          nil -> {:cont, :ok}
          old -> transition(old, item)
        end
      end)
    else
      false -> invalid(:invalid_todo_revision, "existing Todo items cannot be removed or reordered")
    end
  end

  defp transition(old, next) do
    with true <- immutable_item(old) == immutable_item(next),
         :ok <- evidence_extension(old, next),
         :ok <- assignment_transition(old, next),
         :ok <- transition_status(old, next) do
      {:cont, :ok}
    else
      false -> {:halt, invalid(:invalid_todo_revision, "existing Todo definitions are immutable")}
      {:error, %Error{}} = error -> {:halt, error}
    end
  end

  defp evidence_extension(old, next) do
    if Enum.take(next.evidence, length(old.evidence)) == old.evidence do
      :ok
    else
      invalid(:invalid_todo_revision, "Todo evidence is append-only", %{item_id: old.id})
    end
  end

  defp assignment_transition(old, next) do
    cond do
      {old.owner, old.assignment_id} == {next.owner, next.assignment_id} ->
        :ok

      is_nil(old.owner) and is_nil(old.assignment_id) and is_binary(next.owner) and
        is_binary(next.assignment_id) and
          Enum.any?(added_evidence(old, next), &(&1.kind == :assignment)) ->
        :ok

      true ->
        invalid(:invalid_todo_revision, "Todo assignment requires evidence and cannot move", %{
          item_id: old.id
        })
    end
  end

  defp transition_status(%Item{status: status}, %Item{status: status}), do: :ok

  defp transition_status(old, next) do
    required = required_evidence(old.status, next.status)

    if required && Enum.any?(added_evidence(old, next), &(&1.kind == required)) do
      :ok
    else
      invalid(:invalid_todo_transition, "Todo transition requires #{inspect(required)} evidence", %{
        item_id: old.id,
        from: old.status,
        to: next.status
      })
    end
  end

  defp required_evidence(:pending, :in_progress), do: :assignment
  defp required_evidence(status, :blocked) when status in [:pending, :in_progress], do: :blocker
  defp required_evidence(:blocked, status) when status in [:pending, :in_progress], do: :blocker_resolved
  defp required_evidence(status, :completed) when status not in @terminal, do: :completion
  defp required_evidence(status, :cancelled) when status not in @terminal, do: :cancellation
  defp required_evidence(_from, _to), do: nil

  defp immutable_item(item), do: {item.id, item.content, item.dependencies}

  defp added_evidence(old, next), do: Enum.drop(next.evidence, length(old.evidence))

  defp has_evidence?(item, kind), do: Enum.any?(item.evidence, &(&1.kind == kind))

  defp build(id, revision, previous_hash, items) do
    todo = %__MODULE__{
      id: id,
      revision: revision,
      previous_hash: previous_hash,
      items: items,
      active_item_ids: active_ids(items),
      hash: ""
    }

    %{todo | hash: digest(todo_payload(todo))}
  end

  defp active_ids(items), do: for(%Item{status: status, id: id} <- items, status not in @terminal, do: id)

  defp todo_payload(todo) do
    %{
      schema_version: todo.schema_version,
      id: todo.id,
      revision: todo.revision,
      previous_hash: todo.previous_hash,
      items: Enum.map(todo.items, &Map.from_struct/1),
      active_item_ids: todo.active_item_ids
    }
  end

  defp digest(value) do
    value
    |> canonical()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), canonical(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp canonical(value), do: value

  defp atom_keys(map) do
    if Enum.all?(Map.keys(map), &(is_atom(&1) or is_binary(&1))) do
      {:ok,
       Map.new(map, fn
         {key, value} when is_atom(key) -> {key, value}
         {key, value} when is_binary(key) -> {known_key(key), value}
       end)}
    else
      invalid(:invalid_todo_item, "Todo item keys must be strings or atoms")
    end
  end

  defp known_key(key) do
    Enum.find(@item_keys, key, &(Atom.to_string(&1) == key))
  end

  defp string_list(values, _field) when is_list(values) do
    if Enum.all?(values, &(is_binary(&1) and &1 != "")),
      do: {:ok, values},
      else: invalid(:invalid_todo_item, "Todo dependencies must be non-empty strings")
  end

  defp string_list(_values, field), do: invalid(:invalid_todo_item, "Todo #{field} must be a list")

  defp status(value) when value in @statuses, do: {:ok, value}
  defp status(value) when is_binary(value), do: status_string(value)
  defp status(_value), do: invalid(:invalid_todo_item, "invalid Todo status")

  defp status_string(value) do
    case Enum.find(@statuses, &(Atom.to_string(&1) == value)) do
      nil -> invalid(:invalid_todo_item, "invalid Todo status")
      status -> {:ok, status}
    end
  end

  defp evidence(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case evidence_value(value) do
        {:ok, evidence} -> {:cont, {:ok, [evidence | acc]}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, evidence} -> {:ok, Enum.reverse(evidence)}
      error -> error
    end
  end

  defp evidence(_values), do: invalid(:invalid_todo_item, "Todo evidence must be a list")

  defp evidence_value(%{} = value) do
    kind = value[:kind] || value["kind"]
    ref = value[:ref] || value["ref"]
    kind = if is_binary(kind), do: Enum.find(@evidence_kinds, &(Atom.to_string(&1) == kind)), else: kind

    if kind in @evidence_kinds and is_binary(ref) and ref != "" do
      {:ok, %{kind: kind, ref: ref}}
    else
      invalid(:invalid_todo_item, "Todo evidence requires a known kind and non-empty ref")
    end
  end

  defp evidence_value(_value), do: invalid(:invalid_todo_item, "Todo evidence must be a map")

  defp blocker(:blocked, value), do: nonempty(value, :blocker)
  defp blocker(_status, nil), do: :ok
  defp blocker(_status, _value), do: invalid(:invalid_todo_item, "only blocked items may carry a blocker")

  defp optional_string(nil, _field), do: :ok
  defp optional_string(value, field), do: nonempty(value, field)

  defp nonempty(value, _field) when is_binary(value) and value != "", do: :ok
  defp nonempty(_value, field), do: invalid(:invalid_todo_item, "Todo #{field} must be a non-empty string")

  defp invalid(type, message, details \\ %{}), do: {:error, Error.new(type, message, details)}
end
