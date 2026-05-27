defmodule BeamWeaver.Graph.MessagesReducer do
  @moduledoc """
  DeepAgents messages delta reducer.

  This is a thin DeepAgents-facing wrapper over `BeamWeaver.Graph.Messages`.
  It shares BeamWeaver's graph channel implementation with DeepAgents-facing
  code.
  """

  alias BeamWeaver.Graph.Messages

  @spec delta_reducer(list(), list()) :: list()
  defdelegate delta_reducer(state, writes), to: Messages

  @spec remove(String.t()) :: Messages.Remove.t()
  defdelegate remove(id), to: Messages

  @spec remove_all() :: Messages.Remove.t()
  defdelegate remove_all(), to: Messages
end
