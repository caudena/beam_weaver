defmodule BeamWeaver.RetryPredicates do
  @moduledoc """
  Common retry predicates for policy-driven middleware.
  """

  @transient_statuses [408, 409, 425, 429, 500, 502, 503, 504]
  @transient_types [
    :timeout,
    :closed,
    :closed_connection,
    :transport_error,
    :transport_failure,
    :http_error,
    :overloaded,
    :overload,
    :rate_limit,
    :rate_limited,
    :rate_limit_error,
    :transient
  ]

  @spec transient?(term()) :: boolean()
  def transient?(%{details: details, type: type} = error) when is_map(details) do
    retryable_details?(details) or type in @transient_types or transient_message?(details) or
      transient_message?(Map.get(error, :message))
  end

  def transient?(%{type: type}) when type in @transient_types, do: true
  def transient?(%{message: message}), do: transient_message?(message)
  def transient?(error) when is_binary(error), do: transient_message?(error)
  def transient?(_error), do: false

  defp retryable_details?(details) do
    Map.get(details, :retryable) == true or
      Map.get(details, "retryable") == true or
      status(details) in @transient_statuses
  end

  defp status(details), do: Map.get(details, :status) || Map.get(details, "status")

  defp transient_message?(%{} = details) do
    [
      Map.get(details, :reason),
      Map.get(details, "reason"),
      Map.get(details, :message),
      Map.get(details, "message"),
      Map.get(details, :body),
      Map.get(details, "body"),
      inspect(Map.get(details, :error) || Map.get(details, "error"))
    ]
    |> Enum.any?(&transient_message?/1)
  end

  defp transient_message?(message) when is_binary(message) do
    normalized = String.downcase(message)

    Enum.any?(
      [
        "timeout",
        "timed out",
        "closed",
        "connection reset",
        "econnreset",
        "rate limit",
        "rate_limit",
        "too many requests",
        "overload",
        "overloaded",
        "temporarily unavailable",
        "service unavailable"
      ],
      &String.contains?(normalized, &1)
    )
  end

  defp transient_message?(_message), do: false
end
