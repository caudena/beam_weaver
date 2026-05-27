defmodule BeamWeaver.Tracing.Runner do
  @moduledoc false

  alias BeamWeaver.Tracing

  @spec run(String.t() | atom(), keyword(), keyword(), (-> term()), (term(), term() -> term())) ::
          term()
  def run(name, start_opts, exporter_opts, fun, result_fun)
      when is_list(start_opts) and is_list(exporter_opts) and is_function(fun, 0) and
             is_function(result_fun, 2) do
    {:ok, run} = Tracing.start_run(name, exporter_opts ++ start_opts)

    try do
      result = fun.()
      result_fun.(run, result)
    rescue
      exception ->
        Tracing.fail_run(run, exception, exporter_opts)
        reraise exception, __STACKTRACE__
    catch
      kind, reason ->
        Tracing.fail_run(run, %{kind: kind, reason: reason}, exporter_opts)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end
end
