defmodule BeamWeaver.Models.BoundTools do
  @moduledoc false

  @behaviour BeamWeaver.Core.ChatModel

  alias BeamWeaver.Core.ChatModel

  defstruct [:model, tools: [], opts: []]

  @impl true
  def invoke(%__MODULE__{} = wrapper, messages, opts) when is_list(messages) do
    ChatModel.invoke(wrapper.model, messages, merge_opts(wrapper, opts))
  end

  @impl true
  def stream(%__MODULE__{} = wrapper, messages, opts) when is_list(messages) do
    if BeamWeaver.Behaviour.exported?(wrapper.model.__struct__, :stream, 3) do
      wrapper.model.__struct__.stream(wrapper.model, messages, merge_opts(wrapper, opts))
    else
      case invoke(wrapper, messages, opts) do
        {:ok, message} -> {:ok, [message]}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp merge_opts(%__MODULE__{} = wrapper, opts) do
    wrapper.opts
    |> Keyword.merge(opts)
    |> Keyword.update(:tools, wrapper.tools, &(wrapper.tools ++ List.wrap(&1)))
  end
end
