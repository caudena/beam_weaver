defmodule BeamWeaver.OpenAI.Streaming.Lifecycle.State do
  @moduledoc false

  alias BeamWeaver.OpenAI.Streaming.Lifecycle.Content
  alias BeamWeaver.OpenAI.Streaming.Shared

  def initial(parsed_events) do
    %{
      events: [%{"event" => "message-start", "message" => Content.message_start(parsed_events)}],
      next_index: 0,
      blocks: %{},
      item_indexes: %{}
    }
  end

  def finish(state, parsed_events) do
    state
    |> emit(%{"event" => "message-finish", "message" => Content.message_finish(parsed_events)})
    |> Map.fetch!(:events)
    |> Enum.reverse()
  end

  def ensure_block(state, key, content) do
    case Map.get(state.blocks, key) do
      %{finished?: true} ->
        state

      %{index: _index} ->
        state

      nil ->
        index = state.next_index
        block = %{index: index, content: Shared.reject_nil_values(content), finished?: false}

        state
        |> Map.put(:next_index, index + 1)
        |> put_in([:blocks, key], block)
        |> emit(%{
          "event" => "content-block-start",
          "index" => index,
          "content" => block.content
        })
    end
  end

  def delta(state, key, delta) do
    case Map.get(state.blocks, key) do
      %{finished?: true} ->
        state

      %{index: index} ->
        emit(state, %{
          "event" => "content-block-delta",
          "index" => index,
          "delta" => delta
        })

      nil ->
        state
    end
  end

  def finish_block(state, key, content) do
    case Map.get(state.blocks, key) do
      %{finished?: true} ->
        state

      %{index: index} = block ->
        content = content |> Shared.reject_nil_values() |> merge_content(block.content)

        state
        |> put_in([:blocks, key, :finished?], true)
        |> emit(%{
          "event" => "content-block-finish",
          "index" => index,
          "content" => content
        })

      nil ->
        state
        |> ensure_block(key, content)
        |> finish_block(key, content)
    end
  end

  def close_message_parts(state, output_index) do
    state.blocks
    |> Enum.filter(fn
      {{:text, ^output_index, _content_index}, %{finished?: false}} -> true
      _block -> false
    end)
    |> Enum.reduce(state, fn {key, block}, acc ->
      finish_block(acc, key, block.content)
    end)
  end

  def remember_item_index(state, id, index) when is_binary(id) and is_integer(index) do
    put_in(state, [:item_indexes, id], index)
  end

  def remember_item_index(state, _id, _index), do: state

  defp emit(state, event), do: Map.update!(state, :events, &[event | &1])

  defp merge_content(content, started_content) do
    Map.merge(started_content, content, fn _key, started_value, finish_value ->
      if is_nil(finish_value), do: started_value, else: finish_value
    end)
  end
end
