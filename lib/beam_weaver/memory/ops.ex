defmodule BeamWeaver.Memory.GetOp do
  @moduledoc """
  Batch operation for retrieving one memory item.
  """

  @enforce_keys [:namespace, :key]
  defstruct [:namespace, :key, refresh_ttl: true]
end

defmodule BeamWeaver.Memory.SearchOp do
  @moduledoc """
  Batch operation for searching memory items by namespace prefix.
  """

  @enforce_keys [:namespace]
  defstruct [:namespace, filter: %{}, limit: 10, offset: 0, query: nil, refresh_ttl: true]
end

defmodule BeamWeaver.Memory.PutOp do
  @moduledoc """
  Batch operation for storing or deleting a memory item.

  A `nil` value deletes the item, matching LangGraph's `PutOp` behavior.
  """

  @enforce_keys [:namespace, :key]
  defstruct [:namespace, :key, :value, metadata: %{}, index: nil, ttl: :not_provided]
end

defmodule BeamWeaver.Memory.MatchCondition do
  @moduledoc """
  Namespace match condition for list operations.
  """

  @enforce_keys [:type, :path]
  defstruct [:type, :path]
end

defmodule BeamWeaver.Memory.ListNamespacesOp do
  @moduledoc """
  Batch operation for listing namespaces.
  """

  defstruct match_conditions: [], max_depth: nil, limit: 100, offset: 0
end
