defmodule BeamWeaver.OpenAI.Responses.Options do
  @moduledoc """
  Normalized OpenAI Responses request options.
  """

  alias BeamWeaver.OpenAI.ChatModel

  defstruct opts: []

  @type t :: %__MODULE__{opts: keyword()}

  def new(opts \\ []) when is_list(opts), do: %__MODULE__{opts: opts}

  def validate(%__MODULE__{} = options, model),
    do: ChatModel.request_body(model, [], Keyword.put(options.opts, :_validate_only, true))

  def to_body(%__MODULE__{} = options, model, messages),
    do: ChatModel.request_body(model, messages, options.opts)
end
