defmodule BeamWeaver.Agent.Middleware.ToolRetry do
  @moduledoc """
  Retries tool calls that fail, following a `BeamWeaver.RetryPolicy`.

  It takes the retry options of `BeamWeaver.Agent.Middleware.ModelRetry`
  (`:max_retries`, `:initial_delay`, `:backoff`, `:max_delay`, `:jitter`,
  `:retry_on`, which retries every error by default), plus:

    * `:tools` - retry only the calls of these tools.
    * `:on_failure` - what happens once the retries run out: `:error` (the
      default) treats the last failure like any other tool error, `:continue`
      gives the model a message that says how many attempts failed, and a
      one-argument function gives it the text it builds from the
      `%BeamWeaver.Core.Error{}`.
  """

  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.Middleware.RetryRunner
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Options
  alias BeamWeaver.RetryPolicy

  defstruct policy: RetryPolicy.new!(),
            tools: nil,
            on_failure: :error

  def new(opts \\ []) do
    %__MODULE__{
      policy: RetryPolicy.new!(RetryRunner.policy_opts(opts, [:name, :tools, :on_failure])),
      tools: opts |> Keyword.get(:tools) |> normalize_tools(),
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
        {{:error, %Error{} = error}, attempts} -> handle_failure(middleware, request, error, attempts)
        {other, _attempts} -> other
      end
    else
      handler.(request)
    end
  end

  defp retryable_tool_result({:error, %Error{}} = error), do: error

  # The tool node has already turned the error into a message for the model;
  # `error_message` holds the tool's own text.
  defp retryable_tool_result(%Message{role: :tool, metadata: metadata} = message) do
    metadata = metadata || %{}

    if Map.get(metadata, :status) == "error" do
      type = Map.get(metadata, :error_type, :tool_error)
      text = Map.get(metadata, :error_message) || Message.text(message)
      {:error, Error.new(type, text, %{tool_message: message})}
    else
      message
    end
  end

  defp retryable_tool_result(other), do: other

  defp retry_tool?(%__MODULE__{tools: nil}, _request), do: true

  defp retry_tool?(%__MODULE__{tools: tools}, request) do
    MapSet.member?(tools, tool_name(request))
  end

  # The last attempt's tool message already reports the error to the model.
  defp handle_failure(%__MODULE__{on_failure: :error}, _request, %Error{details: %{tool_message: message}}, _attempts),
    do: message

  defp handle_failure(%__MODULE__{on_failure: :error}, _request, %Error{} = error, _attempts),
    do: {:error, error}

  defp handle_failure(%__MODULE__{on_failure: :continue}, request, %Error{} = error, attempts) do
    tool_name = tool_name(request)

    Message.tool(failure_message(tool_name, error, attempts),
      tool_call_id: tool_call_id(request),
      name: tool_name,
      metadata: %{status: "error", error_type: error.type, error_message: error.message}
    )
  end

  defp handle_failure(%__MODULE__{on_failure: fun}, request, %Error{} = error, _attempts)
       when is_function(fun, 1) do
    tool_name = tool_name(request)

    Message.tool(fun.(error),
      tool_call_id: tool_call_id(request),
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

  defp normalize_tools(nil), do: nil

  defp normalize_tools(tools) do
    tools
    |> List.wrap()
    |> Enum.map(fn
      tool when is_binary(tool) -> tool
      tool when is_atom(tool) -> to_string(tool)
      tool -> Tool.name(tool)
    end)
    |> MapSet.new()
  end

  defp normalize_on_failure(:raise), do: :error
  defp normalize_on_failure(:return_message), do: :continue

  defp normalize_on_failure(fun) when is_function(fun, 1), do: fun

  defp normalize_on_failure(value),
    do: Options.atom_enum!("on_failure", value, [:error, :continue])

  defp tool_name(%{tool: nil, tool_call: call}), do: call_name(call)
  defp tool_name(%{tool: tool}), do: Tool.name(tool)

  defp call_name(call) do
    Map.get(call, :name)
  end

  defp tool_call_id(%{tool_call: call}) do
    Map.get(call, :id) ||
      Map.get(call, :tool_call_id)
  end
end
