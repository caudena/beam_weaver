defmodule BeamWeaver.Models.StructuredOutput do
  @moduledoc false

  @behaviour BeamWeaver.Core.ChatModel

  alias BeamWeaver.Agent.StructuredOutput, as: Strategy
  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Message

  defstruct [:model, :schema, opts: []]

  @impl true
  def invoke(%__MODULE__{} = wrapper, messages, opts) when is_list(messages) do
    strategy =
      wrapper.schema
      |> Strategy.normalize()
      |> Strategy.effective_strategy(wrapper.model, Keyword.get(opts, :tools, []))

    call_opts =
      wrapper.opts
      |> Keyword.merge(opts)
      |> Keyword.merge(provider_opts(strategy))
      |> Keyword.update(
        :tools,
        Strategy.setup_tools(strategy),
        &(List.wrap(&1) ++ Strategy.setup_tools(strategy))
      )

    with {:ok, message} <- ChatModel.invoke(wrapper.model, messages, call_opts),
         {:ok, response} <- Strategy.handle_model_output(message, strategy) do
      {:ok, attach_structured_response(message, response)}
    end
  end

  defp provider_opts(%Strategy.ProviderStrategy{} = strategy),
    do: Strategy.provider_opts(strategy)

  defp provider_opts(_strategy), do: []

  defp attach_structured_response(%Message{} = message, %{structured_response: nil}), do: message

  defp attach_structured_response(%Message{} = message, response) do
    metadata =
      message.metadata
      |> Map.put(:structured_response, response.structured_response)
      |> maybe_put_tool_messages(response.messages)

    %{message | metadata: metadata}
  end

  defp maybe_put_tool_messages(metadata, [_message]), do: metadata

  defp maybe_put_tool_messages(metadata, messages) do
    Map.put(metadata, :structured_tool_messages, Enum.drop(messages, 1))
  end
end
