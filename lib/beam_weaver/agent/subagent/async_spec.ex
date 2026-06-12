defmodule BeamWeaver.Agent.Subagent.AsyncSpec do
  @moduledoc "Remote Agent Protocol subagent descriptor."

  defstruct [:name, :description, :graph_id, :url, :client, headers: %{}]

  @type t :: %__MODULE__{
          name: String.t() | nil,
          description: String.t() | nil,
          graph_id: String.t() | nil,
          url: String.t() | nil,
          client: module() | nil,
          headers: map()
        }

  def new(opts \\ []) do
    opts = opts |> Map.new() |> normalize_keys()

    client =
      Map.get(opts, :client) ||
        if Map.get(opts, :url), do: BeamWeaver.Agent.Protocol.ReqClient

    struct(__MODULE__, Map.put(opts, :client, client))
  end

  defp normalize_keys(map) do
    Map.new(map, fn
      {key, _value} when is_binary(key) ->
        raise ArgumentError, "async subagent spec options must use atom keys, got #{inspect(key)}"

      pair ->
        pair
    end)
  end
end
