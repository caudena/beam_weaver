defmodule BeamWeaver.Graph.ServerInfo do
  @moduledoc """
  Server-side graph metadata exposed to nodes and tool runtimes.

  This is a native BeamWeaver struct hydrated from graph config. It covers the
  user-facing LangGraph runtime information without coupling graph execution to
  remote platform SDK objects.
  """

  defmodule User do
    @moduledoc "Authenticated user metadata for graph runtime boundaries."

    defstruct [:identity, :display_name, is_authenticated: nil, permissions: [], metadata: %{}]

    @type t :: %__MODULE__{
            identity: String.t() | nil,
            display_name: String.t() | nil,
            is_authenticated: boolean() | nil,
            permissions: [term()],
            metadata: map()
          }

    def fetch(%__MODULE__{} = user, key) do
      map = to_access_map(user)

      case Map.fetch(map, key) do
        {:ok, _value} = found -> found
        :error when is_atom(key) -> Map.fetch(map, Atom.to_string(key))
        :error -> :error
      end
    end

    def get_and_update(%__MODULE__{} = user, key, fun) do
      map = to_access_map(user)

      case Access.get_and_update(map, key, fun) do
        {current, updated} -> {current, %{user | metadata: Map.merge(user.metadata, updated)}}
      end
    end

    def pop(%__MODULE__{} = user, key) do
      {value, metadata} = Map.pop(to_access_map(user), key)
      {value, %{user | metadata: metadata}}
    end

    defp to_access_map(%__MODULE__{} = user) do
      user.metadata
      |> Map.put_new("identity", user.identity)
      |> Map.put_new("display_name", user.display_name)
      |> Map.put_new("is_authenticated", user.is_authenticated)
      |> Map.put_new("permissions", user.permissions)
    end
  end

  defstruct [:assistant_id, :graph_id, :user, metadata: %{}]

  @type t :: %__MODULE__{
          assistant_id: String.t() | nil,
          graph_id: String.t() | nil,
          user: User.t() | nil,
          metadata: map()
        }

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = normalize_map(opts)

    %__MODULE__{
      assistant_id: maybe_to_string(get(opts, :assistant_id)),
      graph_id: maybe_to_string(get(opts, :graph_id)),
      user: normalize_user(get(opts, :user) || get(opts, :langgraph_auth_user)),
      metadata: Map.get(opts, :metadata, Map.get(opts, "metadata", %{}))
    }
  end

  @spec from_configurable(map() | nil) :: t() | nil
  def from_configurable(nil), do: nil

  def from_configurable(configurable) when is_map(configurable) do
    info =
      new(%{
        assistant_id: get(configurable, :assistant_id),
        graph_id: get(configurable, :graph_id),
        user: get(configurable, :langgraph_auth_user)
      })

    if present?(info.assistant_id) or present?(info.graph_id) or not is_nil(info.user) do
      info
    end
  end

  def from_configurable(_configurable), do: nil

  defp normalize_user(nil), do: nil
  defp normalize_user(%User{} = user), do: user

  defp normalize_user(user) when is_map(user) do
    map = normalize_map(user)
    identity = get(map, :identity) || get(map, :id) || get(map, :sub)

    if present?(identity) do
      %User{
        identity: maybe_to_string(identity),
        display_name: maybe_to_string(get(map, :display_name) || identity),
        is_authenticated: get(map, :is_authenticated),
        permissions: List.wrap(get(map, :permissions) || []),
        metadata: map
      }
    end
  end

  defp normalize_user(_user), do: nil

  defp normalize_map(%{__struct__: _module} = struct), do: Map.from_struct(struct)
  defp normalize_map(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_map(map) when is_map(map), do: map

  defp get(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp maybe_to_string(nil), do: nil
  defp maybe_to_string(value), do: to_string(value)

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_value), do: true
end
