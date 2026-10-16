defmodule BeamWeaver.Provider.StreamFailure do
  @moduledoc false

  require Logger

  alias BeamWeaver.Provider.HTTPClient
  alias BeamWeaver.Transport.Redactor

  # A provider that fails after a stream's 200 response reports the failure in
  # the stream: Anthropic with an `error` event, OpenAI's Responses API (and
  # xAI's and DeepSeek's) with an `error` or a `response.failed` event, Chat
  # Completions APIs and Gemini with a chunk that has an `error` object, and
  # Z.ai and DeepSeek with a finish reason (see `@failed_finish_reasons`).
  # The stream stops at that event. The call fails with the error the
  # provider's decoder makes of a response with the HTTP status the provider
  # gives that error without streaming and the error as its body, so a
  # streamed failure gets the type, and `retryable`, of the same failure
  # without streaming.

  # The HTTP status of each error that a provider's API reference names in
  # its errors' `code` or `type` (Gemini: `status`).
  @documented [
    # Anthropic's error types; DeepSeek's Anthropic-compatible API sends them
    # too.
    anthropic: %{
      400 => ~w(invalid_request_error),
      401 => ~w(authentication_error),
      402 => ~w(billing_error),
      403 => ~w(permission_error),
      404 => ~w(not_found_error),
      409 => ~w(conflict_error),
      413 => ~w(request_too_large),
      429 => ~w(rate_limit_error),
      500 => ~w(api_error),
      504 => ~w(timeout_error),
      529 => ~w(overloaded_error)
    },
    # OpenAI's error codes, including those of a failed Responses API
    # response; xAI and DeepSeek speak the same format.
    openai: %{
      400 => ~w(context_length_exceeded invalid_prompt content_policy_violation bio_policy misalignment_policy_violation
           data_residency_mismatch previous_response_not_found invalid_image invalid_image_format
           invalid_base64_image invalid_image_url image_too_large image_too_small image_parse_error
           image_content_policy_violation invalid_image_mode image_file_too_large unsupported_image_media_type
           empty_image_file failed_to_download_image image_file_not_found),
      401 => ~w(invalid_api_key),
      404 => ~w(model_not_found),
      429 =>
        ~w(rate_limit_exceeded slow_down insufficient_quota credit_balance_exhausted organization_spend_limit_exceeded
           project_spend_limit_exceeded organization_usage_limit_exceeded),
      500 => ~w(server_error),
      503 => ~w(service_unavailable_error server_is_overloaded),
      504 => ~w(vector_store_timeout)
    },
    # Moonshot's (Kimi's) error types.
    moonshot: %{
      400 => ~w(content_filter invalid_request_error),
      401 => ~w(invalid_authentication_error incorrect_api_key_error),
      403 => ~w(permission_denied_error),
      404 => ~w(resource_not_found_error),
      429 => ~w(engine_overloaded_error exceeded_current_quota_error rate_limit_reached_error),
      500 => ~w(server_error unexpected_output),
      503 => ~w(server_unavailable)
    },
    # Z.ai's business codes, and 1303 (requests too frequent), a rate limit
    # its current table leaves out.
    zai: %{
      400 => ~w(1210 1211 1212 1213 1214 1215 1221 1222 1261 1301),
      401 => ~w(1000 1001 1003 1005),
      403 => ~w(1220),
      429 => ~w(1113 1302 1303 1305 1308 1309 1310 1311 1313 1314 1315 1316 1317 1318 1319 1320 1321),
      500 => ~w(1200 1230 1234)
    },
    # The names of Gemini's statuses. Its errors also carry the status as
    # `code`.
    google: %{
      400 => ~w(INVALID_ARGUMENT FAILED_PRECONDITION),
      401 => ~w(UNAUTHENTICATED),
      403 => ~w(PERMISSION_DENIED),
      404 => ~w(NOT_FOUND),
      429 => ~w(RESOURCE_EXHAUSTED),
      500 => ~w(INTERNAL),
      503 => ~w(UNAVAILABLE),
      504 => ~w(DEADLINE_EXCEEDED)
    }
  ]

  # A name two providers share must have one status.
  @statuses (for {_provider, by_status} <- @documented, {status, names} <- by_status, name <- names, reduce: %{} do
               statuses ->
                 Map.update(statuses, name, status, fn
                   ^status -> status
                   _other -> raise ArgumentError, "#{name} has two HTTP statuses"
                 end)
             end)

  # An error no provider documents counts as a server error, which
  # `ModelRetry` retries. A provider reports a failure in the stream after it
  # has accepted the request, its key and its quota, so such a failure is
  # mostly its service failing (an overload, an internal error, a timeout),
  # and the permanent ones (content filters, invalid prompts, a context
  # overflow, an exhausted quota) have documented names. Retrying a permanent
  # failure costs the few calls the retry policy allows; not retrying a
  # transient one fails the run.
  @undocumented_status 500

  # The first time a provider reports such an error, a warning names the
  # provider and the error's code, so a new code gets noticed and added
  # above. The codes warned about are kept in an ETS table that the
  # transport supervisor owns (see `new_table/0`), at most `@max_warned`.
  @warned __MODULE__
  @max_warned 256

  # Z.ai and DeepSeek end a reply they couldn't finish with a finish reason
  # instead of an error, with or without streaming: Z.ai's `network_error`
  # (its inference failed, which its error 1234, a 500, reports otherwise)
  # and `sensitive` (its safety review blocked the reply, as its error 1301,
  # a 400, does; Z.ai asks you to withdraw what you showed of it), and
  # DeepSeek's `insufficient_system_resource` (its inference system ran out
  # of resources, as with its 503) and `aborted` (it interrupted the
  # generation). Such a reply fails with that status. Every other finish
  # reason, such as `length` or OpenAI's `content_filter`, ends a reply its
  # API documents as complete.
  @failed_finish_reasons %{
    "network_error" => {500, "Model inference failed before the reply was complete"},
    "sensitive" => {400, "The provider's safety review blocked the reply"},
    "insufficient_system_resource" => {503, "The provider ran out of resources before the reply was complete"},
    "aborted" => {500, "The provider interrupted the reply"}
  }

  @doc """
  The events before the first one that reports a failure, and that failure as
  `{status, body}`, or `nil` when no event does. `provider` is the provider
  that sent the events, named in the warning about an error no provider
  documents.
  """
  @spec split([map()], atom() | nil) :: {[map()], {100..599, map()} | nil}
  def split(events, provider) do
    case Enum.split_while(events, &is_nil(failure(&1))) do
      {events, []} -> {events, nil}
      {events, [event | _rest]} -> {events, event |> failure() |> with_status(provider)}
    end
  end

  @doc """
  The failure a complete response reports with the finish reason of one of
  its choices, as `{status, body}`, or `nil` when it reports none.
  """
  @spec response_failure(term()) :: {100..599, map()} | nil
  def response_failure(%{"choices" => choices} = response) when is_list(choices),
    do: finish_reason_failure(response, choices)

  def response_failure(_response), do: nil

  @doc """
  The HTTP status a provider gives an error without streaming, or 500 for an
  error no provider documents.
  """
  @spec status(term()) :: 100..599
  def status(error), do: documented(error) || @undocumented_status

  @doc false
  # Creates the table of the errors warned about. The transport supervisor
  # calls it when it starts, so the table lasts as long as the application.
  @spec new_table() :: :ets.table()
  def new_table do
    :ets.new(@warned, [:set, :public, :named_table, read_concurrency: true])
  rescue
    # A supervisor that is still exiting owns the table still.
    ArgumentError -> @warned
  end

  @doc false
  # Adds `key` to `table` unless it is there or the table holds `max` keys
  # already; true when it added it.
  @spec remember(:ets.table(), term(), non_neg_integer()) :: boolean()
  def remember(table, key, max),
    do: not :ets.member(table, key) and :ets.info(table, :size) < max and :ets.insert_new(table, {key})

  # Anthropic sends `{"type": "error", "error": {"type": ..., "message": ...}}`,
  # and so does OpenAI's Responses API sometimes, which otherwise sends
  # `{"type": "error", "code": ..., "message": ...}`, both as an `error`
  # event. A failed Responses API response holds its `error`. Chat
  # Completions and Gemini chunks, which have no `type`, carry an `error`
  # object. Any other `error` event is a failure too, and so is a chunk whose
  # finish reason reports one. An event's failure is the error it reports
  # and the body for the decoder, or, for a finish reason, its status and
  # the body.
  defp failure(%{"data" => %{"type" => "error", "error" => %{} = error} = data}), do: {error, data}

  defp failure(%{"data" => %{"type" => "error"} = data}) do
    error = Map.drop(data, ["type", "sequence_number"])
    {error, %{"error" => error}}
  end

  defp failure(%{"data" => %{"type" => "response.failed", "response" => %{} = response}}) do
    error =
      case response["error"] do
        %{} = error -> error
        _missing -> %{"message" => "Model response failed"}
      end

    {error, %{"error" => error, "response" => response}}
  end

  defp failure(%{"data" => %{"error" => %{} = error} = data}) when not is_map_key(data, "type"), do: {error, data}

  defp failure(%{"event" => "error", "data" => %{} = data}), do: {data, %{"error" => data}}

  defp failure(%{"data" => %{"choices" => choices} = data}) when is_list(choices),
    do: finish_reason_failure(data, choices)

  defp failure(_event), do: nil

  defp with_status({status, body}, _provider) when is_integer(status), do: {status, body}

  defp with_status({error, body}, provider) do
    case documented(error) do
      nil ->
        warn_undocumented(provider, error)
        {@undocumented_status, body}

      status ->
        {status, body}
    end
  end

  defp documented(%{} = error), do: Enum.find_value(["code", "type", "status"], &documented_status(Map.get(error, &1)))
  defp documented(_error), do: nil

  defp warn_undocumented(provider, error) do
    code = code(error)
    if first_warning?({provider, code}), do: Logger.warning(warning(provider, code))
  end

  # The name of the error: its `code`, `type` or `status`, whichever comes
  # first, with any secret redacted, cut short.
  defp code(error) do
    Enum.find_value(["code", "type", "status"], fn field ->
      case Map.get(error, field) do
        code when is_integer(code) -> {field, code}
        code when is_binary(code) and code != "" -> {field, code |> Redactor.redact() |> String.slice(0, 64)}
        _other -> nil
      end
    end)
  end

  # Without the table (the application isn't running) every such error is
  # warned about.
  defp first_warning?(key) do
    remember(@warned, key, @max_warned)
  rescue
    ArgumentError -> true
  end

  defp warning(provider, {field, code}) do
    "#{provider_name(provider)} reported a stream error with #{field} #{inspect(code)}, which BeamWeaver " <>
      "doesn't know, so it was treated as a retryable server error (HTTP #{@undocumented_status}). " <>
      "Please report the #{field} to BeamWeaver so the error can be classified."
  end

  defp warning(provider, nil) do
    "#{provider_name(provider)} reported a stream error without a code, so it was treated as a retryable " <>
      "server error (HTTP #{@undocumented_status})."
  end

  defp provider_name(nil), do: "A provider"
  defp provider_name(provider), do: HTTPClient.provider_label(provider)

  # The body gets an error that names the finish reason as its `code`, which
  # the provider's decoder reads as the error the reason stands for.
  defp finish_reason_failure(body, choices) do
    Enum.find_value(choices, fn
      %{"finish_reason" => reason} when is_map_key(@failed_finish_reasons, reason) ->
        {status, message} = Map.fetch!(@failed_finish_reasons, reason)
        {status, Map.put(body, "error", %{"code" => reason, "message" => "#{message} (finish_reason: #{reason})"})}

      _choice ->
        nil
    end)
  end

  # A code that is an HTTP status, as Gemini's are, is that status.
  defp documented_status(code) when is_integer(code) and code in 400..599, do: code
  defp documented_status(code) when is_integer(code), do: Map.get(@statuses, Integer.to_string(code))

  defp documented_status(name) when is_binary(name) do
    case Integer.parse(name) do
      {code, ""} when code in 400..599 -> code
      _other -> Map.get(@statuses, name)
    end
  end

  defp documented_status(_value), do: nil
end
