defmodule BeamWeaver.OpenAI.Responses.Messages do
  @moduledoc """
  OpenAI Responses API message translator.

  This module preserves a dialect-specific namespace while the source-compatible
  `BeamWeaver.OpenAI.Messages` module remains available.
  """

  alias BeamWeaver.OpenAI.Messages

  defdelegate to_input(messages, opts \\ []), to: Messages, as: :to_responses_input
  defdelegate to_responses_input(messages, opts \\ []), to: Messages
  defdelegate response_to_message(response), to: Messages
  defdelegate normalize_input_items(items), to: Messages
  defdelegate structured_output_format(name, schema, opts \\ []), to: Messages
  defdelegate tool_to_openai(tool), to: Messages
  defdelegate tools_to_openai(tools), to: Messages
end
