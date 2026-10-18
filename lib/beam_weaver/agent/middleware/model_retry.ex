defmodule BeamWeaver.Agent.Middleware.ModelRetry do
  @moduledoc """
  Retries model calls according to a shared `%BeamWeaver.RetryPolicy{}`.

  `:on_failure` (`:error`, `:continue` or a one-argument function) decides
  what happens once the retries run out. An error the policy's `:retry_on`
  doesn't cover is returned as it is, so middleware listed before this one,
  such as `BeamWeaver.Agent.Middleware.ModelFallback`, still gets it.
  """

  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.Middleware.RetryRunner
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Options
  alias BeamWeaver.RetryPolicy

  defstruct policy: RetryPolicy.new!(retry_on: :transient),
            on_failure: :error

  def new(opts \\ []) do
    %__MODULE__{
      policy: RetryPolicy.new!(model_policy_opts(opts)),
      on_failure: opts |> Keyword.get(:on_failure, :error) |> normalize_on_failure()
    }
  end

  @impl true
  def name(_middleware), do: :model_retry

  @impl true
  def wrap_model_call(%__MODULE__{} = middleware, request, handler) do
    case RetryRunner.run_counting(middleware.policy, fn -> handler.(request) end,
           telemetry_prefix: [:beam_weaver, :agent, :model_retry]
         ) do
      # An error the policy doesn't retry goes on as it is, for the middleware
      # around this one, such as `ModelFallback`; `on_failure` handles only
      # the retries running out.
      {:exhausted, error, attempts} -> handle_failure(middleware, error, attempts)
      result -> result
    end
  end

  def retry(%RetryPolicy{} = policy, attempt, fun, telemetry_prefix)
      when is_integer(attempt) and is_function(fun, 0) do
    RetryRunner.run(policy, fun, attempt: attempt, telemetry_prefix: telemetry_prefix)
  end

  defp handle_failure(%__MODULE__{on_failure: :error}, %Error{} = error, _attempts), do: {:error, error}

  defp handle_failure(%__MODULE__{on_failure: on_failure}, %Error{} = error, attempts) do
    text = if on_failure == :continue, do: failure_message(error, attempts), else: on_failure.(error)
    Message.assistant(text, metadata: %{status: "error", error_type: error.type})
  end

  defp failure_message(%Error{} = error, attempts) do
    attempt_word = if attempts == 1, do: "attempt", else: "attempts"
    "Model call failed after #{attempts} #{attempt_word} with #{error.type}: #{error.message}"
  end

  defp normalize_on_failure(fun) when is_function(fun, 1), do: fun

  defp normalize_on_failure(value),
    do: Options.atom_enum!("on_failure", value, [:error, :continue])

  # Model calls retry only transient errors unless told otherwise.
  defp model_policy_opts(opts) do
    opts = if Keyword.has_key?(opts, :policy), do: opts, else: Keyword.put_new(opts, :retry_on, :transient)
    RetryRunner.policy_opts(opts, [:name, :on_failure])
  end
end
