defmodule BeamWeaver.OpenAI.Messages do
  @moduledoc """
  Translators between BeamWeaver core values and OpenAI Responses API payloads.
  """

  alias BeamWeaver.Core.Message
  alias BeamWeaver.OpenAI.Error
  alias BeamWeaver.OpenAI.Messages.Request
  alias BeamWeaver.OpenAI.Messages.Response

  @doc """
  Converts BeamWeaver messages into Responses API `input` items.
  """
  @spec to_responses_input([Message.t()], keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  defdelegate to_responses_input(messages, opts \\ []), to: Request

  @doc """
  Converts a BeamWeaver tool into an OpenAI function tool declaration.
  """
  @spec tool_to_openai(term()) :: map()
  defdelegate tool_to_openai(tool), to: Request

  @doc """
  Converts a list of BeamWeaver tools into OpenAI tool declarations.
  """
  @spec tools_to_openai([term()]) :: [map()]
  defdelegate tools_to_openai(tools), to: Request

  @doc """
  Builds the Responses API JSON schema format shape for structured outputs.
  """
  @spec structured_output_format(String.t(), map(), keyword()) :: map()
  defdelegate structured_output_format(name, schema, opts \\ []), to: Request

  @doc """
  Converts a Responses API or chat-completions JSON response into an assistant message.
  """
  @spec response_to_message(map()) :: {:ok, Message.t()} | {:error, Error.t()}
  defdelegate response_to_message(response), to: Response, as: :to_message

  @doc """
  Normalizes raw Responses API input items.
  """
  @spec normalize_input_items([map()] | nil) :: {:ok, [map()]} | {:error, Error.t()}
  defdelegate normalize_input_items(items), to: Request

  @doc """
  Returns messages after the last assistant message backed by a Responses id.
  """
  @spec last_after_previous_response([Message.t()]) :: {[Message.t()], String.t() | nil}
  defdelegate last_after_previous_response(messages), to: Request
end
