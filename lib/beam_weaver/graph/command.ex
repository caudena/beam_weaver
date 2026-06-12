defmodule BeamWeaver.Graph.Command do
  @moduledoc """
  Runtime command returned by graph nodes.

  `update` is merged into state, `goto` selects the next node or nodes,
  `resume` carries human-in-the-loop resume data, and `graph` targets parent
  or named graph namespaces for subgraph commands.
  """

  @parent :parent

  defstruct update: %{}, goto: nil, resume: nil, graph: nil

  @type t :: %__MODULE__{
          update: map(),
          goto: atom() | String.t() | [atom() | String.t()] | nil,
          resume: term(),
          graph: atom() | String.t() | nil
        }

  @doc "Parent graph target sentinel for subgraph commands."
  def parent, do: @parent
end
