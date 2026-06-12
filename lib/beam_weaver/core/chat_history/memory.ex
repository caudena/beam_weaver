defmodule BeamWeaver.Core.ChatHistory.Memory.Session do
  @moduledoc false

  @behaviour BeamWeaver.Core.ChatHistory

  alias BeamWeaver.Memory

  defstruct [:store, :namespace, :session_id, ttl: nil, metadata: %{}]

  @impl true
  def get_messages(%__MODULE__{} = session) do
    case Memory.get(session.store, session.namespace, session.session_id) do
      {:ok, %{value: messages}} when is_list(messages) -> {:ok, messages}
      :error -> {:ok, []}
      {:error, error} -> {:error, error}
      _other -> {:ok, []}
    end
  end

  @impl true
  def add_messages(%__MODULE__{} = session, messages) when is_list(messages) do
    with {:ok, existing} <- get_messages(session),
         {:ok, _item} <-
           Memory.put(session.store, session.namespace, session.session_id, existing ++ messages,
             ttl: session.ttl,
             metadata: session.metadata
           ) do
      :ok
    end
  end

  @impl true
  def clear(%__MODULE__{} = session) do
    Memory.delete(session.store, session.namespace, session.session_id)
  end
end

defmodule BeamWeaver.Core.ChatHistory.Memory do
  @moduledoc """
  Chat history adapter backed by an explicit `BeamWeaver.Memory` store.
  """

  alias BeamWeaver.Core.ChatHistory.Memory.Session

  defstruct [:store, namespace: ["chat_history"], ttl: nil, metadata: %{}]

  def new(opts) do
    %__MODULE__{
      store: Keyword.fetch!(opts, :store),
      namespace: Keyword.get(opts, :namespace, ["chat_history"]),
      ttl: Keyword.get(opts, :ttl),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  def for_session(%__MODULE__{} = history, session_id) do
    %Session{
      store: history.store,
      namespace: history.namespace,
      session_id: to_string(session_id),
      ttl: history.ttl,
      metadata: history.metadata
    }
  end
end
