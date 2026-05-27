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
      {"name", value} -> {:name, value}
      {"description", value} -> {:description, value}
      {"graph_id", value} -> {:graph_id, value}
      {"url", value} -> {:url, value}
      {"headers", value} -> {:headers, value}
      {"client", value} -> {:client, value}
      pair -> pair
    end)
  end
end
