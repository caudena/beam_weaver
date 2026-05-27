defmodule BeamWeaver.OpenAI.ChatCompletions.Options do
  @moduledoc """
  Normalized OpenAI Chat Completions request options.
  """

  alias BeamWeaver.OpenAI.ChatCompletions.Options.Body
  alias BeamWeaver.OpenAI.ChatCompletions.Options.Validation
  alias BeamWeaver.OpenAI.Error

  defstruct opts: []

  @type t :: %__MODULE__{opts: keyword()}

  def new(opts \\ []) when is_list(opts), do: %__MODULE__{opts: opts}

  @doc "Builds an OpenAI Chat Completions request body."
  @spec to_body(t(), term(), [BeamWeaver.Core.Message.t()]) ::
          {:ok, map()} | {:error, Error.t()}
  defdelegate to_body(options, model, messages), to: Body

  @doc "Validates Chat Completions model options."
  @spec validate(term(), keyword()) :: :ok | {:error, Error.t()}
  defdelegate validate(model, opts), to: Validation
end
