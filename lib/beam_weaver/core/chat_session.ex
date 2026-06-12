defmodule BeamWeaver.Core.ChatSession do
  @moduledoc """
  A loaded chat session.

  This is the Elixir-native equivalent of LangChain's `ChatSession` typed dict:
  messages plus optional function/tool specifications. It stays a plain struct so
  loaders can stream or collect sessions without depending on Python dictionary
  shapes.
  """

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.Utils

  defstruct messages: [], functions: []

  @type t :: %__MODULE__{
          messages: [Message.t()],
          functions: [map()]
        }

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, BeamWeaver.Core.Error.t()}
  def new(attrs \\ []) do
    attrs = Map.new(attrs)

    with {:ok, messages} <- Utils.convert_to_messages(Map.get(attrs, :messages, [])) do
      {:ok,
       %__MODULE__{
         messages: messages,
         functions: List.wrap(Map.get(attrs, :functions, []))
       }}
    end
  end

  @spec new!(map() | keyword()) :: t()
  def new!(attrs \\ []) do
    case new(attrs) do
      {:ok, session} -> session
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = session) do
    %{messages: session.messages, functions: session.functions}
  end
end

defmodule BeamWeaver.Core.ChatLoader do
  @moduledoc """
  Behaviour and facade for chat session loaders.

  Loader modules implement `lazy_load/1`; `load/1` is the native eager helper
  equivalent to LangChain's `list(self.lazy_load())`.
  """

  alias BeamWeaver.Core.ChatSession
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Result

  @callback lazy_load(term()) :: Enumerable.t() | {:ok, Enumerable.t()} | {:error, Error.t()}

  @spec lazy_load(term()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def lazy_load(loader) do
    with {:ok, enumerable} <- call(loader, :lazy_load, [loader]),
         :ok <- ensure_enumerable(enumerable) do
      {:ok, Stream.map(enumerable, &normalize_session!/1)}
    end
  end

  @spec load(term()) :: {:ok, [ChatSession.t()]} | {:error, Error.t()}
  def load(loader) do
    with {:ok, enumerable} <- call(loader, :lazy_load, [loader]),
         :ok <- ensure_enumerable(enumerable) do
      collect_sessions(enumerable)
    end
  end

  defp call(%{__struct__: module}, function, args) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, length(args)) do
      normalize_loader_result(apply(module, function, args))
    else
      unsupported(loader_module: module, function: function)
    end
  end

  defp call(module, function, args) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, length(args)) do
      normalize_loader_result(apply(module, function, args))
    else
      unsupported(loader_module: module, function: function)
    end
  end

  defp call(_loader, function, _args), do: unsupported(function: function)

  defp normalize_loader_result({:ok, enumerable}), do: {:ok, enumerable}
  defp normalize_loader_result({:error, %Error{}} = error), do: error
  defp normalize_loader_result(enumerable), do: {:ok, enumerable}

  defp ensure_enumerable(enumerable) do
    if Enumerable.impl_for(enumerable) do
      :ok
    else
      {:error,
       Error.new(:invalid_chat_loader, "chat loader lazy_load/1 must return an enumerable", %{
         value: inspect(enumerable)
       })}
    end
  end

  defp collect_sessions(enumerable) do
    Result.traverse(enumerable, &normalize_session/1)
  end

  defp normalize_session!(session) do
    case normalize_session(session) do
      {:ok, session} -> session
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp normalize_session(%ChatSession{} = session), do: {:ok, session}
  defp normalize_session(%{} = attrs), do: ChatSession.new(attrs)
  defp normalize_session(attrs) when is_list(attrs), do: ChatSession.new(attrs)

  defp normalize_session(session) do
    {:error,
     Error.new(:invalid_chat_session, "chat loaders must yield chat sessions", %{
       value: inspect(session)
     })}
  end

  defp unsupported(details) do
    {:error,
     Error.new(:unsupported_chat_loader, "chat loader does not implement the contract", %{
       details: details
     })}
  end
end
