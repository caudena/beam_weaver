defmodule BeamWeaver.Stream.Sink do
  @moduledoc """
  Producer-side handle for live stream emission.

  A sink is deliberately small and process-local. It lets producers emit
  typed events through the owning mux while also checking for cancellation.
  """

  alias BeamWeaver.Core.Error

  defstruct [
    :owner,
    :token,
    :name,
    :emit_timeout,
    metadata: %{},
    namespace: []
  ]

  @type t :: %__MODULE__{
          owner: pid(),
          token: reference(),
          name: term(),
          emit_timeout: timeout(),
          metadata: map(),
          namespace: list()
        }

  @spec emit(t(), term()) :: :ok | {:dropped, term()} | {:error, Error.t()}
  def emit(%__MODULE__{} = sink, item) do
    token = sink.token

    if cancelled?(sink) do
      {:error, Error.new(:stream_cancelled, "stream producer was cancelled")}
    else
      ref = make_ref()

      send(
        sink.owner,
        {:beam_weaver_mux_emit, sink.token, ref, self(), sink.name, item,
         %{namespace: sink.namespace, metadata: sink.metadata}}
      )

      receive do
        {:beam_weaver_mux_ack, ^ref, response} ->
          response

        {:beam_weaver_mux_cancel, ^ref} ->
          {:error, Error.new(:stream_cancelled, "stream was cancelled")}

        {:beam_weaver_mux_cancel, ^token} ->
          {:error, Error.new(:stream_cancelled, "stream was cancelled")}
      after
        sink.emit_timeout ->
          {:error, Error.new(:stream_timeout, "stream emit timed out")}
      end
    end
  end

  @spec emit!(t(), term()) :: :ok
  def emit!(%__MODULE__{} = sink, item) do
    case emit(sink, item) do
      :ok -> :ok
      {:dropped, _reason} -> :ok
      {:error, %Error{} = error} -> raise RuntimeError, message: error.message
    end
  end

  @spec cancelled?(t()) :: boolean()
  def cancelled?(%__MODULE__{token: token}) do
    receive do
      {:beam_weaver_mux_cancel, ^token} ->
        Process.put({__MODULE__, token}, true)
        true
    after
      0 ->
        Process.get({__MODULE__, token}, false)
    end
  end

  @spec child(t(), keyword() | term()) :: t()
  def child(%__MODULE__{} = sink, namespace) when not is_list(namespace) do
    child(sink, namespace: sink.namespace ++ [namespace])
  end

  def child(%__MODULE__{} = sink, opts) when is_list(opts) do
    opts =
      if Keyword.keyword?(opts) do
        opts
      else
        [namespace: sink.namespace ++ opts]
      end

    %{
      sink
      | name: Keyword.get(opts, :name, sink.name),
        namespace: Keyword.get(opts, :namespace, sink.namespace),
        metadata: Map.merge(sink.metadata || %{}, Keyword.get(opts, :metadata, %{}))
    }
  end

  @doc false
  def cancel(%__MODULE__{token: token}) do
    send(self(), {:beam_weaver_mux_cancel, token})
    :ok
  end
end
