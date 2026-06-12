defmodule BeamWeaver.Graph.UI do
  @moduledoc """
  UI message helpers equivalent to LangGraph's UI message reducer surface.
  """

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

  @spec state_schema(keyword()) :: map()
  def state_schema(opts \\ []), do: %{ui: channel(opts)}

  @spec channel(keyword()) :: Graph.ChannelSpec.t()
  def channel(opts \\ []),
    do: Graph.channel({BinaryOperatorAggregate, &reducer/2}, Keyword.put_new(opts, :initial, []))

  @spec message(String.t(), map(), keyword()) :: ui_message()
  def message(name, props, opts \\ []) when is_binary(name) and is_map(props) do
    metadata =
      opts
      |> Keyword.get(:metadata, %{})
      |> Map.merge(%{merge: Keyword.get(opts, :merge, false)})
      |> maybe_put(:message_id, message_id(Keyword.get(opts, :message)))

    %{
      type: :ui,
      id: Keyword.get(opts, :id) || BeamWeaver.Core.ID.uuidv7(),
      name: name,
      props: props,
      metadata: metadata
    }
  end

  @spec remove(String.t()) :: remove_message()
  def remove(id) when is_binary(id), do: %{type: :remove_ui, id: id}

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

  @spec reducer(term(), term()) :: [message()]
  def reducer(left, right) do
    left = ui_list(left)
    right = ui_list(right)

    {merged, by_id, removals} =
      Enum.reduce(Enum.with_index(left), {left, %{}, MapSet.new()}, fn {message, index}, {messages, ids, removals} ->
        {messages, Map.put(ids, id!(message), index), removals}
      end)

    {merged, _by_id, removals} =
      Enum.reduce(right, {merged, by_id, removals}, fn message, {messages, by_id, removals} ->
        message_id = id!(message)

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

    Enum.reject(merged, &(id!(&1) in removals))
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

  defp id!(%{id: id}) when is_binary(id), do: id

  defp id!(other) do
    raise ArgumentError, "UI message is missing an ID: #{inspect(other)}"
  end

  defp maybe_put(metadata, _key, nil), do: metadata
  defp maybe_put(metadata, key, value), do: Map.put(metadata, key, value)

  defp message_id(%{id: id}) when is_binary(id), do: id
  defp message_id(%{"id" => id}) when is_binary(id), do: id
  defp message_id(_message), do: nil
end
