defmodule BeamWeaver.Graph.UI do
  @moduledoc """
  Helpers for UI messages kept in graph state.

  A UI message names a client-side component and the props to render it with.
  Nodes send them with `push_ui_message/4` and `delete_ui_message/3`. The
  `reducer/2` behind `channel/1` and `state_schema/1` keeps one entry per id:
  new ids are appended, known ids are replaced (or their props merged when sent
  with `merge: true`), and removals drop the entry.
  """

  import BeamWeaver.MapShape, only: [put_present: 3]

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Channels.BinaryOperatorAggregate
  alias BeamWeaver.Graph.Runtime

  @type ui_message :: %{
          required(:type) => :ui,
          required(:id) => String.t(),
          required(:name) => String.t(),
          required(:props) => map(),
          required(:metadata) => map()
        }

  @type remove_message :: %{required(:type) => :remove_ui, required(:id) => String.t()}
  @type message :: ui_message() | remove_message()

  @doc """
  Returns the ui state channel declaration with an empty-list default.
  """
  @spec state_schema(keyword()) :: map()
  def state_schema(opts \\ []), do: %{ui: channel(opts)}

  @doc """
  Builds the ID-aware UI-message reducer channel.
  """
  @spec channel(keyword()) :: Graph.channel_spec()
  def channel(opts \\ []),
    do: Graph.channel({BinaryOperatorAggregate, &reducer/2}, Keyword.put_new(opts, :initial, []))

  @doc """
  Creates component-name/props data with a stable supplied or generated ID. No component is rendered here.
  """
  @spec message(String.t(), map(), keyword()) :: ui_message()
  def message(name, props, opts \\ []) when is_binary(name) and is_map(props) do
    metadata =
      opts
      |> Keyword.get(:metadata, %{})
      |> Map.merge(%{merge: Keyword.get(opts, :merge, false)})
      |> put_present(:message_id, message_id(Keyword.get(opts, :message)))

    %{
      type: :ui,
      id: Keyword.get(opts, :id) || BeamWeaver.Core.ID.uuidv7(),
      name: name,
      props: props,
      metadata: metadata
    }
  end

  @doc """
  Creates an ID-based UI removal marker.
  """
  @spec remove(String.t()) :: remove_message()
  def remove(id) when is_binary(id), do: %{type: :remove_ui, id: id}

  @doc """
  Emits UI-message data through the runtime writer and returns it for inclusion in state.
  """
  @spec push_ui_message(Runtime.t(), String.t(), map(), keyword()) ::
          {:ok, ui_message()} | {:error, Error.t()}
  def push_ui_message(%Runtime{} = runtime, name, props, opts \\ []) do
    ui_message =
      name
      |> message(props, opts)
      |> put_in([:metadata, :run_id], runtime.run_id)
      |> put_in([:metadata, :name], runtime.node)

    runtime.stream_writer.(%{
      type: :ui,
      message: ui_message,
      state_key: Keyword.get(opts, :state_key, :ui)
    })

    {:ok, ui_message}
  rescue
    exception ->
      {:error, Error.new(:invalid_ui_message, Exception.message(exception))}
  end

  @doc """
  Emits an ID-based UI removal and returns its marker for inclusion in state.
  """
  @spec delete_ui_message(Runtime.t(), String.t(), keyword()) ::
          {:ok, remove_message()} | {:error, Error.t()}
  def delete_ui_message(%Runtime{} = runtime, id, opts \\ []) when is_binary(id) do
    remove = remove(id)

    runtime.stream_writer.(%{
      type: :ui,
      message: remove,
      state_key: Keyword.get(opts, :state_key, :ui)
    })

    {:ok, remove}
  end

  @doc """
  Appends new IDs, updates existing IDs and applies removals. merge metadata merges props; unknown removal IDs raise.
  """
  @spec reducer(term(), term()) :: [message()]
  def reducer(left, right) do
    left = ui_list(left)
    right = ui_list(right)

    by_id = left |> Enum.with_index() |> Map.new(fn {message, index} -> {message.id, index} end)

    {merged, _by_id, removals} =
      Enum.reduce(right, {left, by_id, MapSet.new()}, fn message, {messages, by_id, removals} ->
        message_id = message.id

        case {Map.fetch(by_id, message_id), remove?(message)} do
          {{:ok, _index}, true} ->
            {messages, by_id, MapSet.put(removals, message_id)}

          {{:ok, index}, false} ->
            next = maybe_merge_props(Enum.at(messages, index), message)
            {List.replace_at(messages, index, next), by_id, MapSet.delete(removals, message_id)}

          {:error, true} ->
            raise ArgumentError,
                  "attempting to delete a UI message with an ID that does not exist: #{inspect(message_id)}"

          {:error, false} ->
            {messages ++ [message], Map.put(by_id, message_id, length(messages)), removals}
        end
      end)

    Enum.reject(merged, &(&1.id in removals))
  end

  defp ui_list(nil), do: []
  defp ui_list(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp ui_list(value), do: [normalize(value)]

  defp normalize(%{type: :ui, id: id, name: name, props: props} = message)
       when is_binary(id) and is_binary(name) and is_map(props) do
    Map.put_new(message, :metadata, %{})
  end

  defp normalize(%{"type" => "ui", "id" => id, "name" => name, "props" => props} = message)
       when is_binary(id) and is_binary(name) and is_map(props) do
    %{
      type: :ui,
      id: id,
      name: name,
      props: props,
      metadata: Map.get(message, "metadata", %{})
    }
  end

  defp normalize(%{type: :remove_ui, id: id}) when is_binary(id), do: remove(id)
  defp normalize(%{"type" => "remove-ui", "id" => id}) when is_binary(id), do: remove(id)

  defp normalize(other) do
    raise ArgumentError, "unsupported UI message representation: #{inspect(other)}"
  end

  defp maybe_merge_props(previous, %{type: :ui, metadata: %{merge: true}} = message) do
    %{message | props: Map.merge(previous.props, message.props)}
  end

  defp maybe_merge_props(previous, %{type: :ui, metadata: %{"merge" => true}} = message) do
    %{message | props: Map.merge(previous.props, message.props)}
  end

  defp maybe_merge_props(_previous, message), do: message

  defp remove?(%{type: :remove_ui}), do: true
  defp remove?(_message), do: false

  defp message_id(%{id: id}) when is_binary(id), do: id
  defp message_id(%{"id" => id}) when is_binary(id), do: id
  defp message_id(_message), do: nil
end
