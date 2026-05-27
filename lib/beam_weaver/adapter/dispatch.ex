defmodule BeamWeaver.Adapter.Dispatch do
  @moduledoc false

  alias BeamWeaver.Core.Error

  @type callback :: atom()

  @spec module(term(), callback(), non_neg_integer(), keyword()) ::
          {:ok, module()} | {:error, Error.t()}
  def module(adapter, callback, arity, opts \\ [])

  def module(%{__struct__: adapter_module}, callback, arity, opts) do
    if function_exported?(adapter_module, callback, arity) do
      {:ok, adapter_module}
    else
      {:error,
       Error.new(
         Keyword.get(opts, :error_type, :invalid_adapter),
         Keyword.get(opts, :missing_message, "adapter does not implement required callback"),
         %{
           adapter: inspect(adapter_module),
           callback: callback,
           arity: arity
         }
       )}
    end
  end

  def module(adapter, _callback, _arity, opts) do
    {:error,
     Error.new(
       Keyword.get(opts, :error_type, :invalid_adapter),
       Keyword.get(opts, :invalid_message, "expected an adapter struct"),
       %{adapter: inspect(adapter)}
     )}
  end

  @spec call(term(), callback(), [term()], keyword()) :: term() | {:error, Error.t()}
  def call(adapter, callback, args, opts \\ []) when is_list(args) do
    arity = length(args) + 1

    with {:ok, adapter_module} <- module(adapter, callback, arity, opts) do
      apply(adapter_module, callback, [adapter | args])
    end
  end
end
