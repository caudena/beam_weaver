defmodule BeamWeaver.Agent.Middleware.StructuredOutputRetry do
  @moduledoc """
  Retries model calls whose answer fails the agent's response schema.

  When the answer doesn't parse or validate, the middleware adds that answer
  and the error to the conversation and calls the model again, up to
  `:max_retries` times (1 by default), so the model sees what it got wrong.
  The error goes back as a tool message for each tool call of the answer (the
  tool strategy), or as a user message after it. The saved thread keeps the
  failed answers and the feedback. Once the retries run out, the last error is
  returned.

  Options:

    * `:max_retries` - how many times to ask again.
    * `:feedback` - the error text the model gets: a string in which `{error}`
      stands for the error message, or a function of the
      `%BeamWeaver.Core.Error{}`.
    * `:retry_on` - the error types to retry: by default
      `:structured_output_validation_error`, `:structured_output_parse_error`,
      `:multiple_structured_outputs` and `:missing_structured_output`; a type,
      a list, `:all`, or a function of the type.
  """

  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.Middleware.Helpers
  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Agent.ModelResponse
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message

  @retryable_errors MapSet.new([
                      :structured_output_validation_error,
                      :structured_output_parse_error,
                      :multiple_structured_outputs,
                      :missing_structured_output
                    ])

  defstruct max_retries: 1,
            feedback: nil,
            retry_on: @retryable_errors

  def new(opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, 1)

    if not is_integer(max_retries) or max_retries < 0 do
      raise ArgumentError, "max_retries must be a non-negative integer"
    end

    %__MODULE__{
      max_retries: max_retries,
      feedback: Keyword.get(opts, :feedback),
      retry_on: opts |> Keyword.get(:retry_on, @retryable_errors) |> normalize_retry_on()
    }
  end

  @impl true
  def name(_middleware), do: :structured_output_retry

  @impl true
  def wrap_model_call(%__MODULE__{} = middleware, %ModelRequest{} = request, handler) do
    retry(middleware, request, handler, 0, [])
  end

  defp retry(%__MODULE__{} = middleware, %ModelRequest{} = request, handler, attempt, added) do
    case handler.(request) do
      {:error, %Error{} = error} = result ->
        if retryable?(middleware, error) and attempt < middleware.max_retries do
          exchange = failed_exchange(middleware, error)
          request = ModelRequest.override(request, messages: List.wrap(request.messages) ++ exchange)
          retry(middleware, request, handler, attempt + 1, added ++ exchange)
        else
          result
        end

      {:ok, %ModelResponse{} = response} when added != [] ->
        {:ok, %{response | messages: added ++ response.messages}}

      other ->
        other
    end
  end

  # The model's failed answer followed by the error: a tool message for each
  # of its tool calls, or a user message.
  defp failed_exchange(middleware, %Error{details: %{failed_reply: %Message{} = reply}} = error) do
    feedback = feedback_text(middleware, error)

    case reply.tool_calls do
      [_ | _] = calls -> [reply | Enum.map(calls, &tool_feedback(&1, feedback, error))]
      _none -> [reply, Message.user(feedback)]
    end
  end

  defp failed_exchange(middleware, %Error{} = error), do: [Message.user(feedback_text(middleware, error))]

  defp tool_feedback(call, feedback, %Error{} = error) do
    Message.tool(feedback,
      tool_call_id: Helpers.tool_call_id(call),
      name: Map.get(call, :name),
      metadata: %{status: "error", error_type: error.type}
    )
  end

  defp retryable?(%__MODULE__{retry_on: retry_on}, %Error{type: type}) do
    cond do
      retry_on == :all -> true
      is_function(retry_on, 1) -> retry_on.(type) == true
      true -> MapSet.member?(retry_on, type)
    end
  end

  defp feedback_text(%__MODULE__{feedback: fun}, %Error{} = error) when is_function(fun, 1), do: fun.(error)

  defp feedback_text(%__MODULE__{feedback: template}, %Error{} = error) when is_binary(template),
    do: String.replace(template, "{error}", error.message)

  defp feedback_text(%__MODULE__{}, %Error{} = error) do
    "Your previous response could not be parsed as structured output.\n\n" <>
      "Error: #{error.message}\n" <>
      error_details_text(error) <>
      "Please try again with a valid response."
  end

  defp error_details_text(%Error{details: details}) when is_map(details) and map_size(details) > 0 do
    details
    |> Map.take([:schema, :missing, :key, :expected, :actual, :reason])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> case do
      [] -> ""
      safe_details -> "Details: #{inspect(Map.new(safe_details))}\n"
    end
  end

  defp error_details_text(%Error{}), do: ""

  defp normalize_retry_on(:all), do: :all
  defp normalize_retry_on(%MapSet{} = set), do: set
  defp normalize_retry_on(type) when is_atom(type), do: MapSet.new([type])
  defp normalize_retry_on(types) when is_list(types), do: MapSet.new(types)
  defp normalize_retry_on(fun) when is_function(fun, 1), do: fun

  defp normalize_retry_on(other) do
    raise ArgumentError, "invalid structured output retry_on: #{inspect(other)}"
  end
end
