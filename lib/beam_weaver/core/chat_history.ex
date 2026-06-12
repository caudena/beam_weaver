defmodule BeamWeaver.Core.ChatHistory do
  @moduledoc """
  Minimal chat history contract used by runnable message-history wrappers.
  """

  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.Utils

  @callback get_messages(term()) :: {:ok, [Message.t()]} | {:error, Error.t()}
  @callback add_messages(term(), [Message.t()]) :: :ok | {:error, Error.t()}
  @callback clear(term()) :: :ok | {:error, Error.t()}

  @spec get_messages(term()) :: {:ok, [Message.t()]} | {:error, Error.t()}
  def get_messages(history), do: call(history, :get_messages, [history])

  @spec add_messages(term(), [Message.t()]) :: :ok | {:error, Error.t()}
  def add_messages(history, messages) when is_list(messages) do
    call(history, :add_messages, [history, messages])
  end

  @doc """
  Appends one message to a history.
  """
  @spec add_message(term(), Message.t()) :: :ok | {:error, Error.t()}
  def add_message(history, %Message{} = message), do: add_messages(history, [message])

  @doc """
  Appends a user message built from text or content blocks.
  """
  @spec add_user_message(term(), Message.content(), keyword()) :: :ok | {:error, Error.t()}
  def add_user_message(history, content, opts \\ []) do
    add_message(history, Message.user(content, opts))
  end

  @doc """
  Appends an assistant message built from text or content blocks.
  """
  @spec add_ai_message(term(), Message.content(), keyword()) :: :ok | {:error, Error.t()}
  def add_ai_message(history, content, opts \\ []) do
    add_message(history, Message.assistant(content, opts))
  end

  @spec clear(term()) :: :ok | {:error, Error.t()}
  def clear(history), do: call(history, :clear, [history])

  @doc """
  Renders a history as a role-prefixed message buffer.
  """
  @spec buffer_string(term(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def buffer_string(history, opts \\ []) do
    with {:ok, messages} <- get_messages(history) do
      Utils.get_buffer_string(messages, opts)
    end
  end

  @doc """
  Starts Task-backed message retrieval.
  """
  @spec async_get_messages(term(), keyword()) :: Async.handle()
  def async_get_messages(history, opts \\ []) do
    Async.run(fn -> get_messages(history) end, opts)
  end

  @doc """
  Starts Task-backed message append.
  """
  @spec async_add_messages(term(), [Message.t()], keyword()) :: Async.handle()
  def async_add_messages(history, messages, opts \\ []) do
    Async.run(fn -> add_messages(history, messages) end, opts)
  end

  @doc """
  Starts Task-backed single message append.
  """
  @spec async_add_message(term(), Message.t(), keyword()) :: Async.handle()
  def async_add_message(history, message, opts \\ []) do
    Async.run(fn -> add_message(history, message) end, opts)
  end

  @doc """
  Starts Task-backed history clearing.
  """
  @spec async_clear(term(), keyword()) :: Async.handle()
  def async_clear(history, opts \\ []) do
    Async.run(fn -> clear(history) end, opts)
  end

  defp call(%{__struct__: module}, function, args) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, length(args)) do
      apply(module, function, args)
    else
      unsupported(history_module: module, function: function)
    end
  end

  defp call(module, function, args) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, length(args)) do
      apply(module, function, args)
    else
      unsupported(history_module: module, function: function)
    end
  end

  defp call(_history, function, _args), do: unsupported(function: function)

  defp unsupported(details) do
    {:error,
     Error.new(:unsupported_chat_history, "chat history does not implement the contract", %{
       details: details
     })}
  end
end
