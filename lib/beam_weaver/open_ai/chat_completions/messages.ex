defmodule BeamWeaver.OpenAI.ChatCompletions.Messages do
  @moduledoc """
  OpenAI Chat Completions message translator.
  """

  alias BeamWeaver.Core.Message
  alias BeamWeaver.OpenAI.ChatCompletions.Messages.Request
  alias BeamWeaver.OpenAI.ChatCompletions.Messages.Response
  alias BeamWeaver.OpenAI.ChatCompletions.Messages.Stream
  alias BeamWeaver.OpenAI.Error

  @doc "Converts BeamWeaver messages to OpenAI Chat Completions messages."
  @spec to_openai_messages([Message.t()]) :: {:ok, [map()]} | {:error, Error.t()}
  defdelegate to_openai_messages(messages), to: Request

  @doc "Converts an OpenAI Chat Completions response to a BeamWeaver message."
  @spec response_to_message(map()) :: {:ok, Message.t()} | {:error, Error.t()}
  defdelegate response_to_message(response), to: Response

  @doc "Converts a streamed Chat Completions response body to a BeamWeaver message."
  @spec stream_body_to_message(binary()) :: {:ok, Message.t()} | {:error, Error.t()}
  defdelegate stream_body_to_message(body), to: Stream

  @doc "Builds an OpenAI structured-output response format."
  @spec structured_output_format(String.t(), map(), keyword()) :: map()
  defdelegate structured_output_format(name, schema, opts \\ []), to: Request

  @doc "Converts tools to OpenAI Chat Completions tool declarations."
  @spec tools_to_openai([term()]) :: [map()]
  defdelegate tools_to_openai(tools), to: Request

  @doc "Converts one tool to an OpenAI Chat Completions tool declaration."
  @spec tool_to_openai(term()) :: map()
  defdelegate tool_to_openai(tool), to: Request
end
