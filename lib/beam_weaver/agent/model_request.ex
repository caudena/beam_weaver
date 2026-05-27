defmodule BeamWeaver.Agent.ModelRequest do
  @moduledoc """
  Immutable model-call request passed through agent middleware.
  """

  alias BeamWeaver.Core.Message

  @fields [
    :model,
    :messages,
    :system_message,
    :tool_choice,
    :response_format,
    :tool_set,
    :state,
    :runtime,
    :tools,
    :model_opts
  ]

  defstruct [
    :model,
    :messages,
    :system_message,
    :tool_choice,
    :response_format,
    :tool_set,
    :state,
    :runtime,
    tools: [],
    model_opts: []
  ]

  @type t :: %__MODULE__{
          model: term(),
          messages: [BeamWeaver.Core.Message.t()] | nil,
          system_message: BeamWeaver.Core.Message.t() | [BeamWeaver.Core.Message.t()] | nil,
          tool_choice: term(),
          tools: [term()] | nil,
          tool_set: BeamWeaver.Agent.ToolSet.t() | nil,
          response_format: term(),
          state: map() | nil,
          runtime: BeamWeaver.Graph.Runtime.t() | nil,
          model_opts: keyword() | nil
        }

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = if is_map(opts), do: opts, else: Map.new(opts)

    %__MODULE__{}
    |> override(opts)
    |> then(fn request ->
      %{
        request
        | messages: request.messages || [],
          tools: request.tools || [],
          model_opts: request.model_opts || []
      }
    end)
  end

  @spec system_prompt(t()) :: String.t() | nil
  def system_prompt(%__MODULE__{system_message: nil}), do: nil

  def system_prompt(%__MODULE__{system_message: %Message{} = message}),
    do: Message.text(message)

  def system_prompt(%__MODULE__{system_message: messages}) when is_list(messages) do
    messages
    |> Enum.filter(&match?(%Message{role: :system}, &1))
    |> Enum.map(&Message.text/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> nil
      parts -> Enum.join(parts, "\n")
    end
  end

  @spec override(t(), keyword() | map()) :: t()
  def override(%__MODULE__{} = request, overrides) when is_list(overrides),
    do: override(request, Map.new(overrides))

  def override(%__MODULE__{} = request, overrides) when is_map(overrides) do
    overrides = normalize_system_prompt_overrides(overrides)

    updated =
      Enum.reduce(overrides, request, fn {key, value}, acc ->
        key = normalize_field(key)

        if key in @fields do
          Map.put(acc, key, value)
        else
          acc
        end
      end)

    if Map.has_key?(overrides, :tools) or Map.has_key?(overrides, "tools") do
      tools = Map.get(overrides, :tools, Map.get(overrides, "tools", updated.tools))
      %{updated | tool_set: BeamWeaver.Agent.ToolSet.new(tools, source: :middleware)}
    else
      updated
    end
  end

  defp normalize_system_prompt_overrides(overrides) do
    has_system_message? =
      Map.has_key?(overrides, :system_message) or Map.has_key?(overrides, "system_message")

    has_system_prompt? =
      Map.has_key?(overrides, :system_prompt) or Map.has_key?(overrides, "system_prompt")

    if has_system_message? and has_system_prompt? do
      raise ArgumentError, "cannot specify both system_message and system_prompt"
    end

    if has_system_prompt? do
      prompt = Map.get(overrides, :system_prompt, Map.get(overrides, "system_prompt"))

      overrides
      |> Map.delete(:system_prompt)
      |> Map.delete("system_prompt")
      |> Map.put(:system_message, prompt_to_system_message(prompt))
    else
      overrides
    end
  end

  defp prompt_to_system_message(nil), do: nil
  defp prompt_to_system_message(%Message{role: :system} = message), do: message
  defp prompt_to_system_message(prompt) when is_binary(prompt), do: Message.system(prompt)

  defp prompt_to_system_message(prompt) do
    raise ArgumentError,
          "system_prompt must be a string, system message, or nil, got: #{inspect(prompt)}"
  end

  defp normalize_field(key) when is_atom(key), do: key
  defp normalize_field("model"), do: :model
  defp normalize_field("messages"), do: :messages
  defp normalize_field("system_message"), do: :system_message
  defp normalize_field("tool_choice"), do: :tool_choice
  defp normalize_field("response_format"), do: :response_format
  defp normalize_field("tool_set"), do: :tool_set
  defp normalize_field("state"), do: :state
  defp normalize_field("runtime"), do: :runtime
  defp normalize_field("tools"), do: :tools
  defp normalize_field("model_opts"), do: :model_opts
  defp normalize_field(key), do: key
end
