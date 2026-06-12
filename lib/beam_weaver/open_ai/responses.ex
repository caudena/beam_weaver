defmodule BeamWeaver.OpenAI.Responses do
  @moduledoc """
  Helpers for multi-turn OpenAI Responses API input items.
  """

  alias BeamWeaver.Core.Message

  @doc """
  Builds a raw Responses API message input item.
  """
  @spec message(Message.role() | String.t(), Message.content(), keyword()) :: map()
  def message(role, content, opts \\ []) do
    %{
      "type" => "message",
      "role" => role_to_string(role),
      "content" => content_to_openai(content)
    }
    |> put_optional("id", Keyword.get(opts, :id))
  end

  @doc """
  Returns raw output items from an assistant response message.
  """
  @spec output_items(Message.t()) :: [map()]
  def output_items(%Message{metadata: metadata}) do
    case Map.get(metadata, :output) do
      output when is_list(output) -> output
      _missing -> []
    end
  end

  @doc """
  Returns preserved output items matching `type`.
  """
  @spec output_items(Message.t(), String.t()) :: [map()]
  def output_items(%Message{} = message, type) when is_binary(type) do
    Enum.filter(output_items(message), &(Map.get(&1, "type") == type))
  end

  @doc """
  Builds a function-call output item.
  """
  @spec function_call_output(map() | String.t(), term()) :: map()
  def function_call_output(call_or_id, output) do
    %{
      "type" => "function_call_output",
      "call_id" => call_id(call_or_id),
      "output" => output_to_string(output)
    }
  end

  @doc """
  Builds a custom-tool output item.
  """
  @spec custom_tool_call_output(map() | String.t(), term()) :: map()
  def custom_tool_call_output(call_or_id, output) do
    %{
      "type" => "custom_tool_call_output",
      "call_id" => call_id(call_or_id),
      "output" => output_to_string(output)
    }
  end

  @doc """
  Builds a computer-call output item from an image output.
  """
  @spec computer_call_output(map() | String.t(), term(), keyword()) :: map()
  def computer_call_output(call_or_id, output, opts \\ []) do
    %{
      "type" => "computer_call_output",
      "call_id" => call_id(call_or_id),
      "output" => computer_output(output)
    }
    |> put_optional(
      "acknowledged_safety_checks",
      BeamWeaver.MapShape.normalize_value(Keyword.get(opts, :acknowledged_safety_checks))
    )
  end

  @doc """
   Builds an MCP approval response input item.
  """
  @spec mcp_approval_response(map() | String.t(), boolean()) :: map()
  def mcp_approval_response(request_or_id, approve \\ true) do
    %{
      "type" => "mcp_approval_response",
      "approval_request_id" => approval_request_id(request_or_id),
      "approve" => approve
    }
  end

  @doc """
  Finds the first preserved output item by type.
  """
  @spec first_output_item(Message.t(), String.t()) :: map() | nil
  def first_output_item(%Message{} = message, type) when is_binary(type) do
    message
    |> output_items(type)
    |> List.first()
  end

  defp role_to_string(role) when is_atom(role), do: Atom.to_string(role)
  defp role_to_string(role) when is_binary(role), do: role

  defp content_to_openai(content) when is_binary(content), do: content

  defp content_to_openai(content) when is_list(content) do
    Enum.map(content, &BeamWeaver.MapShape.stringify_keys/1)
  end

  defp call_id(%{"call_id" => call_id}) when is_binary(call_id), do: call_id
  defp call_id(%{call_id: call_id}) when is_binary(call_id), do: call_id
  defp call_id(call_id) when is_binary(call_id), do: call_id

  defp approval_request_id(%{"id" => id}) when is_binary(id), do: id
  defp approval_request_id(%{id: id}) when is_binary(id), do: id
  defp approval_request_id(id) when is_binary(id), do: id

  defp output_to_string(output) when is_binary(output), do: output
  defp output_to_string(output), do: BeamWeaver.JSON.encode!(output)

  defp computer_output([first | _rest]), do: BeamWeaver.MapShape.stringify_keys(first)

  defp computer_output(%{} = output), do: BeamWeaver.MapShape.stringify_keys(output)

  defp computer_output(image_url) when is_binary(image_url) do
    %{"type" => "input_image", "image_url" => image_url}
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
