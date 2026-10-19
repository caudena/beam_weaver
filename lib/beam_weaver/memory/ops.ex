defmodule BeamWeaver.Memory.GetOp do
  @moduledoc """
  Batch operation for retrieving one memory item.

  `refresh_ttl: true` starts the item's lifetime again and `false` leaves it;
  `nil` (the default) follows the store's `:refresh_ttl` option.
  """

  @enforce_keys [:namespace, :key]
  defstruct [:namespace, :key, refresh_ttl: nil]
end

defmodule BeamWeaver.Memory.SearchOp do
  @moduledoc """
  Batch operation for searching memory items by namespace prefix.

  `refresh_ttl: true` starts the lifetime of the items found again and `false`
  leaves it; `nil` (the default) follows the store's `:refresh_ttl` option.
  """

  @enforce_keys [:namespace]
  defstruct [:namespace, filter: %{}, limit: 10, offset: 0, query: nil, refresh_ttl: nil]
end

defmodule BeamWeaver.Memory.PutOp do
  @moduledoc """
  Batch operation for storing or deleting a memory item.

  A `nil` value deletes the item.
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
