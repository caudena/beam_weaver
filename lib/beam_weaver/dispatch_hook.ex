defmodule BeamWeaver.DispatchHook do
  @moduledoc """
  Optional application hook called immediately before an external dispatch.

  Hooks approve with `:ok` and deny with `{:error, reason}`. BeamWeaver assigns
  no policy meaning to the request or context.
  """

  alias BeamWeaver.Adapter.Dispatch

  @callback before_dispatch(struct(), term(), term()) :: :ok | {:error, term()}

  def before(nil, _request, _context), do: :ok

  def before(hook, request, context) do
    case Dispatch.call(hook, :before_dispatch, [request, context], error_type: :invalid_dispatch_hook) do
      :ok -> :ok
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_dispatch_hook_result, other}}
    end
  end

  def run(hook, request, context, fun) when is_function(fun, 0) do
    with :ok <- before(hook, request, context), do: fun.()
  end
end
