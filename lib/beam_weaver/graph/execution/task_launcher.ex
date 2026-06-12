defmodule BeamWeaver.Graph.Execution.TaskLauncher do
  @moduledoc false

  alias BeamWeaver.Tracing

  @spec start(map(), (-> term())) :: Task.t()
  def start(run, fun) when is_function(fun, 0) do
    trace_context = Map.get(run, :trace_context)
    wrapped = fn -> Tracing.attach_context(trace_context, fun) end

    case run.task_supervisor do
      nil -> Task.async(wrapped)
      supervisor -> Task.Supervisor.async_nolink(supervisor, wrapped)
    end
  end
end
