defmodule BeamWeaver.Tools.Todo do
  @moduledoc """
  State tool that updates explicit agent state through graph commands.
  """

  @behaviour BeamWeaver.Core.Tool

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph.Command

  defstruct state_key: :todos,
            name: "todo",
            description: "Manage an explicit TODO list in agent state."

  def new(opts \\ []) do
    %__MODULE__{
      state_key: Keyword.get(opts, :state_key, :todos),
      name: Keyword.get(opts, :name, "todo"),
      description: Keyword.get(opts, :description, "Manage an explicit TODO list in agent state.")
    }
  end

  @impl true
  def name(%__MODULE__{name: name}), do: name

  @impl true
  def description(%__MODULE__{description: description}), do: description

  @impl true
  def input_schema(_tool) do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{"type" => "string", "enum" => ["add", "update", "complete", "list"]},
        "id" => %{"type" => "string"},
        "text" => %{"type" => "string"},
        "status" => %{"type" => "string", "enum" => ["open", "complete"]}
      },
      "required" => ["action"]
    }
  end

  @impl true
  def injected(_tool), do: %{state: :state, tool_call_id: :tool_call_id}

  @impl true
  def return_direct(_tool), do: false

  @impl true
  def response_format(_tool), do: nil

  @impl true
  def output_schema(_tool), do: %{"type" => "object"}

  @impl true
  def tags(_tool), do: [:todo]

  @impl true
  def metadata(_tool), do: %{}

  @impl true
  def provider_opts(_tool), do: %{}

  @impl true
  def invoke(%__MODULE__{} = tool, input, _opts) do
    state = Map.get(input, :state) || Map.get(input, "state") || %{}
    call_id = Map.get(input, :tool_call_id) || Map.get(input, "tool_call_id")
    todos = Map.get(state, tool.state_key, Map.get(state, to_string(tool.state_key), [])) || []

    with {:ok, todos, result} <- apply_action(todos, input) do
      message =
        Message.tool(BeamWeaver.JSON.encode!(result),
          tool_call_id: call_id,
          name: name(tool),
          metadata: %{status: "success"}
        )

      {:ok, %Command{update: %{tool.state_key => todos, messages: [message]}}}
    end
  end

  defp apply_action(todos, input) do
    action = input |> get_value(:action) |> normalize_action()
    id = get_value(input, :id)
    text = get_value(input, :text)
    status = input |> get_value(:status) |> normalize_status()

    case action do
      "add" ->
        with {:ok, text} <- require_text(text) do
          id = id || unique_id()
          todo = %{id: id, text: text, status: "open"}
          updated = todos ++ [todo]
          {:ok, updated, %{todos: updated, changed: todo}}
        end

      "update" ->
        with {:ok, id} <- require_id(id),
             {:ok, text} <- require_text(text),
             {:ok, updated} <- update_todo(todos, id, %{text: text}, "update") do
          {:ok, updated, %{todos: updated, changed_id: id}}
        end

      "complete" ->
        with {:ok, id} <- require_id(id),
             {:ok, updated} <- update_todo(todos, id, %{status: status || "complete"}, "complete") do
          {:ok, updated, %{todos: updated, changed_id: id}}
        end

      "list" ->
        {:ok, todos, %{todos: todos}}

      other ->
        {:error,
         Error.new(:invalid_todo_action, "todo action must be add, update, complete, or list", %{
           action: other
         })}
    end
  end

  defp update_todo(todos, id, changes, action) do
    {updated, changed?} =
      Enum.map_reduce(todos, false, fn todo, changed? ->
        if todo_id(todo) == to_string(id) do
          {merge_todo(todo, changes), true}
        else
          {todo, changed?}
        end
      end)

    if changed? do
      {:ok, updated}
    else
      {:error, Error.new(:todo_not_found, "todo id was not found", %{id: id, action: action})}
    end
  end

  defp merge_todo(todo, changes) do
    Enum.reduce(changes, todo, fn {key, value}, acc ->
      cond do
        is_map(acc) and Map.has_key?(acc, key) -> Map.put(acc, key, value)
        is_map(acc) and Map.has_key?(acc, to_string(key)) -> Map.put(acc, to_string(key), value)
        true -> Map.put(acc, key, value)
      end
    end)
  end

  defp require_id(id) when is_binary(id) and id != "", do: {:ok, id}
  defp require_id(id) when is_integer(id), do: {:ok, to_string(id)}

  defp require_id(_id),
    do: {:error, Error.new(:invalid_todo_id, "todo id must be a non-empty string")}

  defp require_text(text) when is_binary(text) do
    text = String.trim(text)

    if text == "" do
      {:error, Error.new(:invalid_todo_text, "todo text must be a non-empty string")}
    else
      {:ok, text}
    end
  end

  defp require_text(_text),
    do: {:error, Error.new(:invalid_todo_text, "todo text must be a non-empty string")}

  defp normalize_action(nil), do: nil
  defp normalize_action(action) when is_atom(action), do: Atom.to_string(action)
  defp normalize_action(action), do: to_string(action)

  defp normalize_status(nil), do: nil
  defp normalize_status(status) when status in ["open", "complete"], do: status

  defp normalize_status(status) when is_atom(status),
    do: status |> Atom.to_string() |> normalize_status()

  defp normalize_status(_status), do: "complete"

  defp get_value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp todo_id(todo), do: to_string(Map.get(todo, :id) || Map.get(todo, "id"))

  defp unique_id do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary({System.unique_integer([:positive]), self()}))
    |> Base.encode16(case: :lower)
  end
end
