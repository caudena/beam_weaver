defmodule BeamWeaver.Agent.Middleware.StructuredOutputRetry do
  @moduledoc """
  Retries model calls that fail structured-output parsing or validation.

  The middleware keeps retry behavior at the BeamWeaver model-call boundary. It
  does not expose Python exception classes; recoverable failures remain tagged
  `%BeamWeaver.Core.Error{}` values.
  """

  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Agent.ModelResponse
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message

  @retryable_errors MapSet.new([
                      :structured_output_validation_error,
                      :structured_output_parse_error,
                      :multiple_structured_outputs
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

  def wrap_model_call(%__MODULE__{} = middleware, %ModelRequest{} = request, handler) do
    retry(middleware, request, handler, 0, [])
  end

  defp retry(%__MODULE__{} = middleware, %ModelRequest{} = request, handler, attempt, feedback) do
    case handler.(request) do
      {:error, %Error{} = error} = result ->
        if retryable?(middleware, error) and attempt < middleware.max_retries do
          message = feedback_message(middleware, error)

          request =
            ModelRequest.override(request,
              messages: List.wrap(request.messages) ++ [message]
            )

          retry(middleware, request, handler, attempt + 1, feedback ++ [message])
        else
          result
        end

      {:ok, %ModelResponse{} = response} when feedback != [] ->
        {:ok, %{response | messages: feedback ++ response.messages}}

      other ->
        other
    end
  end

  defp retryable?(%__MODULE__{retry_on: retry_on}, %Error{type: type}) do
    cond do
      retry_on == :all -> true
      is_function(retry_on, 1) -> retry_on.(type) == true
      true -> MapSet.member?(retry_on, type)
    end
  end

  defp feedback_message(%__MODULE__{feedback: fun}, %Error{} = error) when is_function(fun, 1) do
    Message.user(fun.(error))
  end

  defp feedback_message(%__MODULE__{feedback: template}, %Error{} = error)
       when is_binary(template) do
    Message.user(String.replace(template, "{error}", error.message))
  end

  defp feedback_message(%__MODULE__{}, %Error{} = error) do
    Message.user(
      "Your previous response could not be parsed as structured output.\n\n" <>
        "Error: #{error.message}\n" <>
        error_details_text(error) <>
        "Please try again with a valid response."
    )
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
