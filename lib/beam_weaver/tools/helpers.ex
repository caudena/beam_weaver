defmodule BeamWeaver.Tools.Helpers do
  @moduledoc """
  Helpers for inspecting and rewriting DeepAgents tool inputs.

  These are the BeamWeaver-native equivalents of Python DeepAgents `_tools.py`.
  They are intentionally copy-on-write so caller-owned tool definitions are not
  mutated when harness profiles override model-visible descriptions.
  """

  alias BeamWeaver.Core.Tool

  @doc "Extracts a tool name from maps, `%Tool{}` values, or behaviour structs."
  @spec tool_name(term()) :: String.t() | nil
  def tool_name(%Tool{name: name}) when is_binary(name), do: name

  def tool_name(tool) when is_map(tool) do
    case Map.get(tool, :name, Map.get(tool, "name")) do
      name when is_binary(name) -> name
      _other -> nil
    end
  end

  def tool_name(module) when is_atom(module) do
    if function_exported?(module, :name, 1) do
      name = module.name(module)
      if is_binary(name), do: name
    end
  rescue
    _exception -> nil
  end

  def tool_name(_tool), do: nil

  @doc """
  Applies description overrides to supported tool definitions without mutation.

  `%Tool{}` structs and map tools are copied with the new description. Other
  values are returned unchanged because wrapping arbitrary functions or
  behaviour modules would change identity and invocation semantics.
  """
  @spec apply_tool_description_overrides([term()] | nil, map()) :: [term()] | nil
  def apply_tool_description_overrides(nil, _overrides), do: nil

  def apply_tool_description_overrides(tools, overrides) when is_map(overrides) do
    Enum.map(List.wrap(tools), fn tool ->
      case {tool_name(tool), tool} do
        {name, %Tool{} = tool} when is_binary(name) ->
          override_tool_struct(tool, override_for(overrides, name))

        {name, tool} when is_binary(name) and is_map(tool) ->
          override_tool_map(tool, override_for(overrides, name))

        _other ->
          tool
      end
    end)
  end

  def apply_tool_description_overrides(tools, _overrides), do: List.wrap(tools)

  defp override_tool_struct(tool, nil), do: tool
  defp override_tool_struct(%Tool{} = tool, description), do: %{tool | description: description}

  defp override_tool_map(tool, nil), do: tool

  defp override_tool_map(tool, description) do
    if Map.has_key?(tool, :description) do
      Map.put(tool, :description, description)
    else
      Map.put(tool, "description", description)
    end
  end

  defp override_for(overrides, name) do
    case Map.get(overrides, name, atom_key_value(overrides, name)) do
      description when is_binary(description) -> description
      _other -> nil
    end
  end

  defp atom_key_value(overrides, name) do
    Enum.find_value(overrides, fn
      {key, value} when is_atom(key) ->
        if Atom.to_string(key) == name, do: value

      _other ->
        nil
    end)
  end
end
