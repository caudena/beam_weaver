defmodule BeamWeaver.Provider.Outcome do
  @moduledoc """
  Closed provider-turn classification used by durable runtimes.

  Provider status is evidence, not control flow. This module converts that
  evidence and the normalized message shape into the three independent axes
  needed by callers before any tool is dispatched.
  """

  import BeamWeaver.Provider.ChatCompletionsWire, only: [metadata_value: 2]

  alias BeamWeaver.Core.Message

  @remote_statuses ~w(not_applicable queued in_progress requires_action paused completed incomplete failed cancelled expired unknown)a
  @turn_dispositions ~w(final_output awaiting_client_tools awaiting_user_input provider_pause refusal filtered context_limit output_limit budget_exhausted remote_resource_exhausted no_usable_output)a
  @result_completeness ~w(complete partial absent unknown)a

  @enforce_keys [:remote_status, :turn_disposition, :result_completeness]
  defstruct [:remote_status, :turn_disposition, :result_completeness]

  @type t :: %__MODULE__{
          remote_status: atom(),
          turn_disposition: atom(),
          result_completeness: atom()
        }

  @spec classify(Message.t()) :: t()
  def classify(%Message{} = message) do
    status = normalize_status(message.status || metadata_value(message.response_metadata, :status))
    incomplete_reason = incomplete_reason(message.response_metadata)

    cond do
      refusal?(message) ->
        outcome(:completed, :refusal, :complete)

      # Anthropic's safety classifiers end a reply they decline with the
      # `refusal` stop reason, in a normal response.
      status == "refusal" ->
        outcome(:completed, :refusal, completeness(message))

      filtered?(status, message) ->
        outcome(:completed, :filtered, completeness(message))

      # The Responses API ends a reply that its content filter cut off as
      # incomplete, where Chat Completions has the `content_filter` finish
      # reason.
      status == "incomplete" and incomplete_reason == "content_filter" ->
        outcome(:incomplete, :filtered, completeness(message))

      invalid_tool_calls?(message) ->
        outcome(remote_status(status), :awaiting_client_tools, :partial)

      status in ["max_tokens", "max_output_tokens", "length"] ->
        outcome(:incomplete, :output_limit, :partial)

      # Anthropic and Z.ai end a reply that filled the model's context window
      # with the `model_context_window_exceeded` stop reason.
      status == "model_context_window_exceeded" ->
        outcome(:incomplete, :context_limit, :partial)

      status == "incomplete" and context_limit?(incomplete_reason) ->
        outcome(:incomplete, :context_limit, :partial)

      # xAI ends a reply that ran out of the time it may take as incomplete,
      # with the `max_time_limit` reason.
      status == "incomplete" and incomplete_reason == "max_time_limit" ->
        outcome(:incomplete, :budget_exhausted, :partial)

      status == "incomplete" ->
        outcome(:incomplete, :output_limit, :partial)

      status in ["pause_turn", "paused"] ->
        outcome(:paused, :provider_pause, completeness(message))

      status in ["requires_action", "tool_use", "tool_calls"] ->
        outcome(:requires_action, :awaiting_client_tools, :complete)

      message.tool_calls != [] ->
        outcome(:requires_action, :awaiting_client_tools, :complete)

      status in ["failed", "error"] ->
        outcome(:failed, :no_usable_output, completeness(message))

      status in ["cancelled", "canceled"] ->
        outcome(:cancelled, :no_usable_output, completeness(message))

      status == "expired" ->
        outcome(:expired, :no_usable_output, completeness(message))

      status in ["queued", "in_progress"] ->
        outcome(remote_status(status), :no_usable_output, completeness(message))

      Message.text(message) != "" or hosted_result?(message) ->
        outcome(:completed, :final_output, :complete)

      true ->
        outcome(remote_status(status), :no_usable_output, :absent)
    end
  end

  defp hosted_result?(message) do
    message.server_tool_results != [] or
      Enum.any?(List.wrap(metadata_value(message.metadata, :output)), fn item ->
        is_map(item) and
          Map.get(item, "type") not in [
            "function_call",
            "custom_tool_call",
            "computer_call",
            "apply_patch_call",
            "local_shell_call"
          ] and
          (Map.get(item, "result") not in [nil, "", []] or Map.get(item, "output") not in [nil, "", []])
      end)
  end

  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{} = outcome) do
    outcome.remote_status in @remote_statuses and
      outcome.turn_disposition in @turn_dispositions and
      outcome.result_completeness in @result_completeness
  end

  defp outcome(remote_status, turn_disposition, result_completeness) do
    %__MODULE__{
      remote_status: remote_status,
      turn_disposition: turn_disposition,
      result_completeness: result_completeness
    }
  end

  defp completeness(%Message{} = message) do
    if Message.text(message) == "" and message.tool_calls == [], do: :absent, else: :partial
  end

  defp remote_status(nil), do: :not_applicable
  defp remote_status("queued"), do: :queued
  defp remote_status("in_progress"), do: :in_progress
  defp remote_status("completed"), do: :completed
  defp remote_status("cancelled"), do: :cancelled
  defp remote_status("canceled"), do: :cancelled
  defp remote_status("expired"), do: :expired
  defp remote_status(_status), do: :unknown

  defp refusal?(%Message{} = message),
    do: message |> blocks() |> Enum.any?(&(metadata_value(&1, :type) in [:refusal, "refusal"]))

  # The finish reasons of a reply a content filter stopped: Chat Completions'
  # `content_filter`, and Gemini's safety, recitation, blocklist,
  # prohibited-content and personal-data stops, for text and for images.
  @filtered_statuses ~w(content_filter safety blocked recitation blocklist prohibited_content spii
                        image_safety image_prohibited_content image_recitation)

  defp filtered?(status, %Message{} = message) do
    status in @filtered_statuses or
      blocked_prompt_feedback?(metadata_value(message.response_metadata, :prompt_feedback))
  end

  defp blocked_prompt_feedback?(feedback) when is_map(feedback) do
    reason =
      Map.get(feedback, :block_reason) || Map.get(feedback, "block_reason") ||
        Map.get(feedback, :blockReason) || Map.get(feedback, "blockReason")

    reason not in [nil, "", :BLOCK_REASON_UNSPECIFIED, "BLOCK_REASON_UNSPECIFIED"] or
      Map.get(feedback, :blocked) == true or Map.get(feedback, "blocked") == true
  end

  defp blocked_prompt_feedback?(feedback) when is_binary(feedback),
    do: feedback not in ["", "BLOCK_REASON_UNSPECIFIED"]

  defp blocked_prompt_feedback?(_feedback), do: false

  defp invalid_tool_calls?(%Message{} = message) do
    case metadata_value(message.metadata, :invalid_tool_calls) do
      calls when is_list(calls) -> calls != []
      _other -> false
    end
  end

  # xAI's reason for a prompt longer than the model takes is
  # `max_prompt_tokens`.
  defp context_limit?(reason) do
    reason in ["context_length_exceeded", "context_limit", "max_input_tokens", "max_prompt_tokens"]
  end

  defp incomplete_reason(metadata) when is_map(metadata) do
    details = metadata_value(metadata, :incomplete_details)
    normalize_status(metadata_value(details, :reason) || metadata_value(details, :type))
  end

  defp incomplete_reason(_metadata), do: nil

  defp blocks(%Message{content: content}) when is_list(content), do: content
  defp blocks(_message), do: []

  defp normalize_status(nil), do: nil
  defp normalize_status(value), do: value |> to_string() |> String.downcase()
end
