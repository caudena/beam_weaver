defmodule BeamWeaver.OpenAI.Streaming.Lifecycle do
  @moduledoc false

  alias BeamWeaver.OpenAI.Streaming.Lifecycle.Content
  alias BeamWeaver.OpenAI.Streaming.Lifecycle.State
  alias BeamWeaver.OpenAI.Streaming.Shared
  alias BeamWeaver.OpenAI.Streaming.SSE

  @output_item_types [
    "image_generation_call",
    "web_search_call",
    "file_search_call",
    "code_interpreter_call",
    "mcp_call",
    "mcp_list_tools",
    "mcp_approval_request",
    "tool_search_call",
    "tool_search_output",
    "custom_tool_call",
    "compaction"
  ]

  @spec events(binary() | [map()] | term()) :: [map()]
  def events(body) when is_binary(body) do
    body
    |> SSE.events()
    |> events()
  end

  def events(parsed_events) when is_list(parsed_events) do
    if parsed_events == [] do
      []
    else
      parsed_events
      |> Enum.reduce(State.initial(parsed_events), &apply_lifecycle_event/2)
      |> State.finish(parsed_events)
    end
  end

  def events(_body), do: []

  defp apply_lifecycle_event(
         %{"data" => %{"type" => "response.output_item.added", "item" => item} = data},
         state
       )
       when is_map(item) do
    output_index = data["output_index"]
    item = Shared.stringify_keys(item)

    state
    |> State.remember_item_index(item["id"], output_index)
    |> maybe_start_output_item(output_index, item)
  end

  defp apply_lifecycle_event(
         %{
           "data" =>
             %{
               "type" => "response.content_part.added",
               "part" => %{"type" => type} = part
             } = data
         },
         state
       )
       when type in ["output_text", "text"] do
    State.ensure_block(state, Content.text_block_key(data), Content.text(data, part))
  end

  defp apply_lifecycle_event(
         %{"data" => %{"type" => "response.output_text.delta", "delta" => delta} = data},
         state
       )
       when is_binary(delta) do
    state
    |> State.ensure_block(Content.text_block_key(data), Content.text(data, %{}))
    |> State.delta(Content.text_block_key(data), %{"type" => "text-delta", "text" => delta})
  end

  defp apply_lifecycle_event(
         %{"data" => %{"type" => "response.output_text.done", "text" => text} = data},
         state
       )
       when is_binary(text) do
    state
    |> State.ensure_block(Content.text_block_key(data), Content.text(data, %{}))
    |> State.finish_block(Content.text_block_key(data), Content.text(data, %{"text" => text}))
  end

  defp apply_lifecycle_event(
         %{"data" => %{"type" => "response.content_part.done", "part" => part} = data},
         state
       )
       when is_map(part) do
    part = Shared.stringify_keys(part)

    if part["type"] in ["output_text", "text"] do
      state
      |> State.ensure_block(Content.text_block_key(data), Content.text(data, part))
      |> State.finish_block(Content.text_block_key(data), Content.text(data, part))
    else
      state
    end
  end

  defp apply_lifecycle_event(
         %{"data" => %{"type" => "response.reasoning_summary_part.added"} = data},
         state
       ) do
    State.ensure_block(state, Content.reasoning_block_key(data), Content.reasoning(data, %{}))
  end

  defp apply_lifecycle_event(
         %{
           "data" =>
             %{
               "type" => "response.reasoning_summary_text.delta",
               "delta" => delta
             } = data
         },
         state
       )
       when is_binary(delta) do
    state
    |> State.ensure_block(Content.reasoning_block_key(data), Content.reasoning(data, %{}))
    |> State.delta(Content.reasoning_block_key(data), %{
      "type" => "reasoning-delta",
      "reasoning" => delta
    })
  end

  defp apply_lifecycle_event(
         %{
           "data" =>
             %{
               "type" => "response.reasoning_summary_text.done",
               "text" => text
             } = data
         },
         state
       )
       when is_binary(text) do
    state
    |> State.ensure_block(Content.reasoning_block_key(data), Content.reasoning(data, %{}))
    |> State.finish_block(
      Content.reasoning_block_key(data),
      Content.reasoning(data, %{"text" => text})
    )
  end

  defp apply_lifecycle_event(
         %{"data" => %{"type" => "response.reasoning_summary_part.done", "part" => part} = data},
         state
       )
       when is_map(part) do
    state
    |> State.ensure_block(Content.reasoning_block_key(data), Content.reasoning(data, part))
    |> State.finish_block(Content.reasoning_block_key(data), Content.reasoning(data, part))
  end

  defp apply_lifecycle_event(
         %{
           "data" =>
             %{
               "type" => "response.function_call_arguments.delta",
               "delta" => delta
             } = data
         },
         state
       )
       when is_binary(delta) do
    state
    |> State.ensure_block(Content.function_block_key(data), Content.tool_call_chunk(data))
    |> State.delta(Content.function_block_key(data), %{
      "type" => "block-delta",
      "fields" => %{"type" => "tool_call_chunk", "args" => delta}
    })
  end

  defp apply_lifecycle_event(
         %{
           "data" =>
             %{
               "type" => "response.function_call_arguments.done",
               "arguments" => arguments
             } = data
         },
         state
       )
       when is_binary(arguments) do
    State.ensure_block(state, Content.function_block_key(data), Content.tool_call_chunk(data))
  end

  defp apply_lifecycle_event(
         %{"data" => %{"type" => "response.output_item.done", "item" => item} = data},
         state
       )
       when is_map(item) do
    item = Shared.stringify_keys(item)
    output_index = data["output_index"]

    state
    |> State.remember_item_index(item["id"], output_index)
    |> finish_output_item(output_index, item)
  end

  defp apply_lifecycle_event(_event, state), do: state

  defp maybe_start_output_item(state, output_index, %{"type" => "function_call"} = item) do
    State.ensure_block(state, {:function_call, output_index}, Content.tool_call_chunk(item))
  end

  defp maybe_start_output_item(state, output_index, %{"type" => type} = item)
       when type in @output_item_types do
    State.ensure_block(state, {:output_item, output_index}, item)
  end

  defp maybe_start_output_item(state, _output_index, _item), do: state

  defp finish_output_item(state, output_index, %{"type" => "function_call"} = item) do
    State.finish_block(state, {:function_call, output_index}, Content.tool_call(item))
  end

  defp finish_output_item(state, output_index, %{"type" => "reasoning"} = item) do
    if Content.reasoning_has_summary?(item) do
      state
    else
      content = %{
        "type" => "reasoning",
        "id" => item["id"],
        "reasoning" => ""
      }

      state
      |> State.ensure_block({:output_item, output_index}, content)
      |> State.finish_block({:output_item, output_index}, content)
    end
  end

  defp finish_output_item(state, output_index, %{"type" => "message"}),
    do: State.close_message_parts(state, output_index)

  defp finish_output_item(state, output_index, %{"type" => type} = item)
       when type in @output_item_types do
    state
    |> State.ensure_block({:output_item, output_index}, item)
    |> State.finish_block({:output_item, output_index}, item)
  end

  defp finish_output_item(state, _output_index, _item), do: state
end
