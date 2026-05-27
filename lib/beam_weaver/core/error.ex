defmodule BeamWeaver.Core.Error do
  @moduledoc """
  Recoverable error returned by core behaviours.
  """

  @enforce_keys [:type, :message]
  defstruct [:type, :message, details: %{}]

  @type t :: %__MODULE__{
          type: atom(),
          message: String.t(),
          details: map()
        }

  @error_codes %{
    invalid_prompt_input: "INVALID_PROMPT_INPUT",
    invalid_tool_results: "INVALID_TOOL_RESULTS",
    message_coercion_failure: "MESSAGE_COERCION_FAILURE",
    model_authentication: "MODEL_AUTHENTICATION",
    model_not_found: "MODEL_NOT_FOUND",
    model_rate_limit: "MODEL_RATE_LIMIT",
    output_parsing_failure: "OUTPUT_PARSING_FAILURE"
  }

  @doc """
  Builds a core error.
  """
  @spec new(atom(), String.t(), map()) :: t()
  def new(type, message, details \\ %{}) when is_atom(type) and is_binary(message) do
    %__MODULE__{type: type, message: message, details: details}
  end

  @spec error_codes() :: map()
  def error_codes, do: @error_codes

  @spec create_message(String.t(), atom() | String.t()) :: String.t()
  def create_message(message, error_code) when is_binary(message) do
    code = error_code_value(error_code)

    message <>
      "\nFor troubleshooting, visit: https://docs.langchain.com/oss/python/langchain/errors/" <>
      code <> " "
  end

  @spec output_parser(term(), keyword()) :: t() | {:error, t()}
  def output_parser(error, opts \\ []) do
    observation = Keyword.get(opts, :observation)
    llm_output = Keyword.get(opts, :llm_output)
    send_to_llm = Keyword.get(opts, :send_to_llm, false)

    if send_to_llm and (is_nil(observation) or is_nil(llm_output)) do
      {:error,
       new(
         :invalid_output_parser_error,
         "observation and llm_output are required when send_to_llm is true"
       )}
    else
      message =
        if is_binary(error),
          do: create_message(error, :output_parsing_failure),
          else: inspect(error)

      new(:output_parser, message, %{
        observation: observation,
        llm_output: llm_output,
        send_to_llm: send_to_llm
      })
    end
  end

  @spec context_overflow(String.t(), map()) :: t()
  def context_overflow(message, details \\ %{}), do: new(:context_overflow, message, details)

  @spec tracer(String.t(), map()) :: t()
  def tracer(message, details \\ %{}), do: new(:tracer, message, details)

  defp error_code_value(error_code) when is_atom(error_code) do
    Map.fetch!(@error_codes, error_code)
  end

  defp error_code_value(error_code) when is_binary(error_code), do: error_code
end
