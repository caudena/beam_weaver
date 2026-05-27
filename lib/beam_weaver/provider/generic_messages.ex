defmodule BeamWeaver.Provider.GenericMessages do
  @moduledoc """
  Conservative provider message translation for providers without full adapters.

  This keeps provider maps at the boundary and preserves unknown blocks instead
  of dropping data while richer provider-specific translators are added.
  """

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message

  @providers [:google_vertexai, :bedrock, :bedrock_converse, :groq]

  def providers, do: @providers

  def encode(%Message{} = message, provider) when provider in @providers do
    {:ok,
     %{
       provider: provider,
       role: message.role,
       content: message.content,
       id: message.id,
       name: message.name,
       tool_calls: message.tool_calls,
       tool_call_id: message.tool_call_id,
       metadata: message.metadata,
       response_metadata: message.response_metadata,
       usage_metadata: message.usage_metadata,
       unknown_blocks: unknown_blocks(message.content)
     }}
  end

  def decode(%{} = payload, provider) when provider in @providers do
    role = payload[:role] || payload["role"] || :assistant
    content = payload[:content] || payload["content"] || ""

    Message.new(role_atom(role), content,
      id: payload[:id] || payload["id"],
      name: payload[:name] || payload["name"],
      tool_calls: payload[:tool_calls] || payload["tool_calls"] || [],
      tool_call_id: payload[:tool_call_id] || payload["tool_call_id"],
      metadata: payload[:metadata] || payload["metadata"] || %{},
      response_metadata: payload[:response_metadata] || payload["response_metadata"] || %{},
      usage_metadata: payload[:usage_metadata] || payload["usage_metadata"]
    )
  end

  defp role_atom(role) when role in [:system, :user, :assistant, :tool], do: role
  defp role_atom("system"), do: :system
  defp role_atom("user"), do: :user
  defp role_atom("human"), do: :user
  defp role_atom("assistant"), do: :assistant
  defp role_atom("ai"), do: :assistant
  defp role_atom("tool"), do: :tool
  defp role_atom(_role), do: :assistant

  defp unknown_blocks(content) when is_list(content) do
    Enum.reject(content, fn
      %ContentBlock.Text{} -> true
      %ContentBlock.PlainText{} -> true
      %{type: type} -> type in [:text, :plain_text]
      _other -> false
    end)
  end

  defp unknown_blocks(_content), do: []
end
