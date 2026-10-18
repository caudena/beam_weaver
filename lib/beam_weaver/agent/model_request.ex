defmodule BeamWeaver.Agent.ModelRequest do
  @moduledoc """
  Immutable model-call request passed through agent middleware.
  """

  alias BeamWeaver.Core.Message

  defstruct [
    :model,
    :system_message,
    :tool_choice,
    :response_format,
    :tool_set,
    :runtime,
    messages: [],
    state: %{},
    tools: [],
    model_opts: []
  ]

  @type t :: %__MODULE__{
          model: term(),
          messages: [BeamWeaver.Core.Message.t()],
          system_message: BeamWeaver.Core.Message.t() | [BeamWeaver.Core.Message.t()] | nil,
          tool_choice: term(),
          tools: [term()],
          tool_set: term(),
          response_format: term(),
          state: map(),
          runtime: BeamWeaver.Graph.Runtime.t() | nil,
          model_opts: keyword()
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts), do: override(%__MODULE__{}, opts)

  @spec system_prompt(t()) :: String.t() | nil
  def system_prompt(%__MODULE__{system_message: nil}), do: nil

  def system_prompt(%__MODULE__{system_message: %Message{} = message}),
    do: Message.text(message)

  def system_prompt(%__MODULE__{system_message: messages}) when is_list(messages) do
    case for(%Message{role: :system} = message <- messages, text = Message.text(message), text != "", do: text) do
      [] -> nil
      parts -> Enum.join(parts, "\n")
    end
  end

  @doc """
  Returns a copy of the request with the given fields replaced.

  `:system_prompt` is accepted as a string shorthand for `:system_message`.
  Replacing `:tools` also rebuilds the request's tool set.
  """
  @spec override(t(), keyword()) :: t()
  def override(%__MODULE__{} = request, overrides) when is_list(overrides) do
    overrides = put_system_prompt(overrides, Keyword.pop(overrides, :system_prompt, :unset))
    updated = struct!(request, overrides)

    case Keyword.fetch(overrides, :tools) do
      {:ok, tools} -> %{updated | tool_set: BeamWeaver.Agent.ToolSet.new(tools, source: :middleware)}
      :error -> updated
    end
  end

  defp put_system_prompt(overrides, {:unset, _rest}), do: overrides

  defp put_system_prompt(_overrides, {prompt, rest}) do
    if Keyword.has_key?(rest, :system_message),
      do: raise(ArgumentError, "cannot specify both system_message and system_prompt")

    Keyword.put(rest, :system_message, prompt_to_system_message(prompt))
  end

  defp prompt_to_system_message(nil), do: nil
  defp prompt_to_system_message(%Message{role: :system} = message), do: message
  defp prompt_to_system_message(prompt) when is_binary(prompt), do: Message.system(prompt)

  defp prompt_to_system_message(prompt) do
    raise ArgumentError,
          "system_prompt must be a string, system message, or nil, got: #{inspect(prompt)}"
  end
end
