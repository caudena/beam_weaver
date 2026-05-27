defmodule BeamWeaver.OpenAI.Streaming.Lifecycle.Content do
  @moduledoc false

  alias BeamWeaver.OpenAI.Streaming.Shared

  def message_start(parsed_events), do: parsed_events |> first_response() |> response_message()

  def message_finish(parsed_events),
    do: parsed_events |> Shared.terminal_response() |> response_message()

  def text_block_key(data) do
    {:text, data["output_index"], Map.get(data, "content_index", 0)}
  end

  def text(data, part) do
    part = Shared.stringify_keys(part)

    part
    |> Map.drop(["type"])
    |> Map.merge(%{
      "type" => "text",
      "id" => data["item_id"],
      "text" => Map.get(part, "text", "")
    })
  end

  def reasoning_block_key(data) do
    {:reasoning, data["output_index"], Map.get(data, "summary_index", 0)}
  end

  def reasoning(data, part) do
    part = Shared.stringify_keys(part)

    %{
      "type" => "reasoning",
      "id" => data["item_id"],
      "reasoning" => Map.get(part, "text", "")
    }
  end

  def function_block_key(%{"output_index" => output_index}), do: {:function_call, output_index}

  def function_block_key(%{"item_id" => item_id}) when is_binary(item_id),
    do: {:function_call, item_id}

  def function_block_key(_data), do: {:function_call, nil}

  def tool_call_chunk(%{"item_id" => item_id} = data) do
    %{
      "type" => "tool_call_chunk",
      "id" => item_id,
      "name" => data["name"],
      "args" => ""
    }
    |> Shared.reject_nil_values()
  end

  def tool_call_chunk(item) do
    %{
      "type" => "tool_call_chunk",
      "id" => item["call_id"] || item["id"],
      "name" => item["name"],
      "args" => item["arguments"] || ""
    }
    |> Shared.reject_nil_values()
  end

  def tool_call(data, arguments \\ nil) do
    arguments = arguments || data["arguments"] || ""

    %{
      "type" => "tool_call",
      "id" => data["call_id"] || data["item_id"] || data["id"],
      "name" => data["name"],
      "args" => Shared.decode_arguments(arguments)
    }
    |> Shared.reject_nil_values()
  end

  def reasoning_has_summary?(%{"summary" => summary}) when is_list(summary), do: summary != []
  def reasoning_has_summary?(_item), do: false

  defp first_response(parsed_events) do
    Enum.find_value(parsed_events, %{}, fn
      %{"data" => %{"response" => response}} when is_map(response) ->
        Shared.stringify_keys(response)

      _event ->
        nil
    end)
  end

  defp response_message(response) do
    %{
      "id" => response["id"],
      "model" => response["model"],
      "usage" => response["usage"]
    }
    |> Shared.reject_nil_values()
  end
end
