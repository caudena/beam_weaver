defmodule BeamWeaver.Provider.ToolRenderer do
  @moduledoc """
  Behaviour for rendering BeamWeaver tools into provider-native declarations.
  """

  alias BeamWeaver.Core.Error

  @callback render_tools([term()], keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  @callback render_tool_choice(term(), [term()], keyword()) :: {:ok, term()} | {:error, Error.t()}

  @optional_callbacks render_tool_choice: 3
end
