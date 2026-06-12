defmodule BeamWeaver.Agent.Middleware.ModelRetry do
  @moduledoc """
  Retries model calls according to a shared `%BeamWeaver.RetryPolicy{}`.
  """

  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.Middleware.RetryRunner
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Options
  alias BeamWeaver.RetryPolicy

  defstruct policy: RetryPolicy.new!(),
            on_failure: :error

  def new(opts \\ []) do
    %__MODULE__{
      policy: RetryPolicy.new!(RetryRunner.policy_opts(opts, [:name, :on_failure])),
      on_failure: opts |> Keyword.get(:on_failure, :error) |> normalize_on_failure()
    }
  end

  @impl true
  def name(_middleware), do: :model_retry

  def wrap_model_call(%__MODULE__{} = middleware, request, handler) do
    case RetryRunner.run(middleware.policy, fn -> handler.(request) end,
           telemetry_prefix: [:beam_weaver, :agent, :model_retry]
         ) do
      {:error, %Error{} = error} -> handle_failure(middleware, error)
      other -> other
    end
  end

  def retry(%RetryPolicy{} = policy, attempt, fun, telemetry_prefix)
      when is_integer(attempt) and is_function(fun, 0) do
    RetryRunner.run(policy, fun, attempt: attempt, telemetry_prefix: telemetry_prefix)
  end

  defp handle_failure(%__MODULE__{on_failure: :error}, %Error{} = error), do: {:error, error}

  defp handle_failure(%__MODULE__{on_failure: :continue, policy: policy}, %Error{} = error) do
    Message.assistant(failure_message(error, policy.max_attempts),
      metadata: %{status: "error", error_type: error.type}
    )
  end

  defp handle_failure(%__MODULE__{on_failure: fun}, %Error{} = error) when is_function(fun, 1) do
    Message.assistant(fun.(error), metadata: %{status: "error", error_type: error.type})
  end

  defp failure_message(%Error{} = error, attempts) do
    attempt_word = if attempts == 1, do: "attempt", else: "attempts"
    "Model call failed after #{attempts} #{attempt_word} with #{error.type}: #{error.message}"
  end

  defp normalize_on_failure(fun) when is_function(fun, 1), do: fun

  defp normalize_on_failure(value),
    do: Options.atom_enum!("on_failure", value, [:error, :continue])
end
