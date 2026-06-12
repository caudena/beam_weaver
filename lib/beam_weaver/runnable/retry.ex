defmodule BeamWeaver.Runnable.Retry do
  @moduledoc false

  @behaviour BeamWeaver.Runnable

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Runnable

  defstruct [:runnable, opts: []]

  @impl true
  def invoke(%__MODULE__{runnable: runnable, opts: retry_opts}, input, opts) do
    max_attempts = Keyword.get(retry_opts, :max_attempts, Keyword.get(retry_opts, :attempts, 3))
    retry(runnable, input, opts, max(max_attempts, 1), nil)
  end

  defp retry(_runnable, _input, _opts, 0, %Error{} = last_error), do: {:error, last_error}

  defp retry(runnable, input, opts, attempts_left, _last_error) do
    case Runnable.invoke(runnable, input, opts) do
      {:ok, output} -> {:ok, output}
      {:error, %Error{} = error} -> retry(runnable, input, opts, attempts_left - 1, error)
    end
  end
end
