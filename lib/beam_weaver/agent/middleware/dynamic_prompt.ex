defmodule BeamWeaver.Agent.Middleware.DynamicPrompt do
  @moduledoc """
  Replaces or computes the system prompt for each model call.
  """

  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Core.Message

  defstruct prompt: nil

  def new(opts \\ []), do: %__MODULE__{prompt: Keyword.fetch!(opts, :prompt)}

  @impl true
  def name(_middleware), do: :dynamic_prompt

  def wrap_model_call(%__MODULE__{prompt: prompt}, %ModelRequest{} = request, handler) do
    request
    |> ModelRequest.override(system_message: resolve_prompt(prompt, request))
    |> handler.()
  end

  defp resolve_prompt(%Message{role: :system} = prompt, _request), do: prompt
  defp resolve_prompt(prompt, _request) when is_binary(prompt), do: Message.system(prompt)
  defp resolve_prompt(fun, request) when is_function(fun, 1), do: normalize(fun.(request))

  defp resolve_prompt(fun, request) when is_function(fun, 2),
    do: normalize(fun.(request.state, request.runtime))

  defp resolve_prompt({module, function, args}, request),
    do: normalize(apply(module, function, [request | args]))

  defp resolve_prompt(_prompt, request), do: request.system_message

  defp normalize(%Message{role: :system} = prompt), do: prompt
  defp normalize(prompts) when is_list(prompts), do: prompts
  defp normalize(prompt) when is_binary(prompt), do: Message.system(prompt)
  defp normalize(nil), do: nil
end
