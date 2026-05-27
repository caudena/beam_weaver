defmodule BeamWeaver.Core.ChatHistory.ETS.Session do
  @moduledoc "Session-scoped ETS chat history adapter."

  @behaviour BeamWeaver.Core.ChatHistory

  defstruct [:table, :session_id]

  @type t :: %__MODULE__{table: :ets.tid(), session_id: String.t()}

  @impl true
  def get_messages(%__MODULE__{table: table, session_id: session_id}) do
    {:ok,
     case :ets.lookup(table, session_id) do
       [{^session_id, messages}] -> messages
       [] -> []
     end}
  end

  @impl true
  def add_messages(%__MODULE__{} = session, messages) when is_list(messages) do
    {:ok, existing} = get_messages(session)
    :ets.insert(session.table, {session.session_id, existing ++ messages})
    :ok
  end

  @impl true
  def clear(%__MODULE__{table: table, session_id: session_id}) do
    :ets.delete(table, session_id)
    :ok
  end
end

defmodule BeamWeaver.Core.ChatHistory.ETS do
  @moduledoc """
  ETS-backed chat history store for tests and local examples.
  """

  alias BeamWeaver.Core.ChatHistory.ETS.Session

  defstruct [:table]

  @type t :: %__MODULE__{table: :ets.tid()}

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    table =
      Keyword.get_lazy(opts, :table, fn ->
        :ets.new(:beam_weaver_chat_history, [:set, :public, {:read_concurrency, true}])
      end)

    %__MODULE__{table: table}
  end

  @spec for_session(t(), term()) :: Session.t()
  def for_session(%__MODULE__{table: table}, session_id) do
    %Session{table: table, session_id: to_string(session_id)}
  end
end
