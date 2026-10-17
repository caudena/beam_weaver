defmodule BeamWeaver.Agent.Subagent.AsyncSpec do
  @moduledoc "Remote Agent Protocol subagent descriptor."

  use BeamWeaver.Provider.RedactedInspect

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
    opts = Map.new(opts)

    case Enum.find(Map.keys(opts), &is_binary/1) do
      nil -> :ok
      key -> raise ArgumentError, "async subagent spec options must use atom keys, got #{inspect(key)}"
    end

    client =
      Map.get(opts, :client) ||
        if Map.get(opts, :url), do: BeamWeaver.Agent.Protocol.ReqClient

    struct(__MODULE__, Map.put(opts, :client, client))
  end
end
