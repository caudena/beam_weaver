defmodule BeamWeaver.Agent.Middleware.ToolChoice do
  @moduledoc """
  Sets provider tool-choice options for model calls.

  This is intentionally small middleware: it does not add or remove tools. It
  only forwards a tool-choice policy to the provider for agents that need the
  next model turn to use a specific tool or any tool.
  """

  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Core.Tool

  defstruct choice: nil,
            when_tool_present: nil

  def new(opts \\ []) do
    %__MODULE__{
      choice: Keyword.get(opts, :choice, Keyword.get(opts, :tool_choice)),
      when_tool_present:
        opts
        |> Keyword.get(:when_tool_present)
        |> normalize_tool_names()
    }
  end

  @impl true
  def name(_middleware), do: :tool_choice

  def wrap_model_call(%__MODULE__{} = middleware, %ModelRequest{} = request, handler) do
    if apply_choice?(middleware, request) do
      request
      |> ModelRequest.override(tool_choice: resolve_choice(middleware.choice, request))
      |> handler.()
    else
      handler.(request)
    end
  end

  defp apply_choice?(%__MODULE__{choice: nil}, _request), do: false

  defp apply_choice?(%__MODULE__{when_tool_present: []}, _request), do: true
  defp apply_choice?(%__MODULE__{when_tool_present: nil}, _request), do: true

  defp apply_choice?(%__MODULE__{when_tool_present: required}, %ModelRequest{} = request) do
    names =
      request.tools
      |> List.wrap()
      |> Enum.map(&Tool.name/1)
      |> MapSet.new()

    Enum.all?(required, &MapSet.member?(names, &1))
  end

  defp resolve_choice(choice, request) when is_function(choice, 1), do: choice.(request)
  defp resolve_choice(choice, _request), do: choice

  defp normalize_tool_names(nil), do: nil

  defp normalize_tool_names(values) do
    values
    |> List.wrap()
    |> Enum.map(&to_string/1)
  end
end
