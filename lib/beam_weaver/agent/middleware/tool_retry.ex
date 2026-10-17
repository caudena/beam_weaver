defmodule BeamWeaver.Agent.Middleware.ToolRetry do
  @moduledoc """
  Retries tool calls that fail, following a `BeamWeaver.RetryPolicy`.

  It takes the retry options of `BeamWeaver.Agent.Middleware.ModelRetry`
  (`:max_retries`, `:initial_delay`, `:backoff`, `:max_delay`, `:jitter`,
  `:retry_on`, which by default retries every error except one that says
  retrying can't help, such as a model call's invalid API key), plus:

    * `:tools` - retry only the calls of these tools.
    * `:on_failure` - what happens once the retries run out: `:error` (the
      default) treats the last failure like any other tool error, `:continue`
      gives the model a message that says how many attempts failed, and a
      one-argument function gives it the text it builds from the
      `%BeamWeaver.Core.Error{}`. An error `:retry_on` doesn't cover reaches
      the model as the tool returned it.
  """

  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.Middleware.Helpers
  alias BeamWeaver.Agent.Middleware.RetryRunner
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Options
  alias BeamWeaver.RetryPolicy

  defstruct policy: RetryPolicy.new!(),
            tools: nil,
            on_failure: :error

  def new(opts \\ []) do
    %__MODULE__{
      policy: RetryPolicy.new!(RetryRunner.policy_opts(opts, [:name, :tools, :on_failure])),
      tools: opts |> Keyword.get(:tools) |> Helpers.tool_names(),
      on_failure: opts |> Keyword.get(:on_failure, :error) |> normalize_on_failure()
    }
  end

  @impl true
  def name(_middleware), do: :tool_retry

  @impl true
  def wrap_tool_call(%__MODULE__{} = middleware, request, handler) do
    if retry_tool?(middleware, request) do
      case RetryRunner.run_counting(
             middleware.policy,
             fn -> handler.(request) |> retryable_tool_result() end,
             telemetry_prefix: [:beam_weaver, :agent, :tool_retry]
           ) do
        # An error the policy doesn't retry goes on as the tool returned it;
        # `on_failure` handles only the retries running out.
        {{:error, %Error{} = error}, attempts} ->
          if RetryPolicy.retry?(middleware.policy, error),
            do: handle_failure(middleware, request, error, attempts),
            else: tool_result(error)

        {other, _attempts} ->
          other
      end
    else
      handler.(request)
    end
  end

  defp retryable_tool_result(result) do
    case Helpers.tool_failure(result) do
      nil -> result
      error -> {:error, error}
    end
  end

  defp tool_result(%Error{details: %{tool_message: message}}), do: message
  defp tool_result(%Error{} = error), do: {:error, error}

  defp retry_tool?(%__MODULE__{tools: nil}, _request), do: true

  defp retry_tool?(%__MODULE__{tools: tools}, request) do
    MapSet.member?(tools, Helpers.tool_name(request))
  end

  # The last attempt's tool message already reports the error to the model.
  defp handle_failure(%__MODULE__{on_failure: :error}, _request, %Error{details: %{tool_message: message}}, _attempts),
    do: message

  defp handle_failure(%__MODULE__{on_failure: :error}, _request, %Error{} = error, _attempts),
    do: {:error, error}

  defp handle_failure(%__MODULE__{on_failure: on_failure}, request, %Error{} = error, attempts) do
    tool_name = Helpers.tool_name(request)
    text = if on_failure == :continue, do: failure_message(tool_name, error, attempts), else: on_failure.(error)

    Message.tool(text,
      tool_call_id: Helpers.tool_call_id(request.tool_call),
      name: tool_name,
      metadata: %{status: "error", error_type: error.type, error_message: error.message}
    )
  end

  defp failure_message(tool_name, %Error{} = error, attempts) do
    attempt_word = if attempts == 1, do: "attempt", else: "attempts"

    "Tool '#{tool_name}' failed after #{attempts} #{attempt_word} with #{error.type}: " <>
      sentence(error.message) <> " Please try again."
  end

  defp sentence(text) do
    text = String.trim_trailing(text)
    if String.ends_with?(text, [".", "!", "?"]), do: text, else: text <> "."
  end

  defp normalize_on_failure(:raise), do: :error
  defp normalize_on_failure(:return_message), do: :continue

  defp normalize_on_failure(fun) when is_function(fun, 1), do: fun

  defp normalize_on_failure(value),
    do: Options.atom_enum!("on_failure", value, [:error, :continue])
end
