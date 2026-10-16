defmodule BeamWeaver.Core.Messages.ToolCall do
  @moduledoc "Normalized model tool call."
  defstruct [:id, :provider_id, :call_id, :name, :thought_signature, args: %{}, type: :tool_call]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          provider_id: String.t() | nil,
          call_id: String.t() | nil,
          name: String.t() | nil,
          thought_signature: String.t() | nil,
          args: map(),
          type: atom()
        }
end

defmodule BeamWeaver.Core.Messages.ToolCallChunk do
  @moduledoc "Incremental model tool-call chunk."
  defstruct [:id, :index, :name, args: "", type: :tool_call_chunk]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          index: integer() | nil,
          name: String.t() | nil,
          args: String.t() | nil,
          type: atom()
        }
end

defmodule BeamWeaver.Core.Messages.InvalidToolCall do
  @moduledoc "Tool call that could not be parsed."
  defstruct [:id, :provider_id, :call_id, :name, :args, :error, type: :invalid_tool_call]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          provider_id: String.t() | nil,
          call_id: String.t() | nil,
          name: String.t() | nil,
          args: term(),
          error: String.t() | nil,
          type: atom()
        }
end

defmodule BeamWeaver.Core.Messages.Chunk do
  @moduledoc false
  defstruct [
    :role,
    :content,
    :id,
    :name,
    :tool_call_id,
    metadata: %{},
    tool_calls: [],
    tool_call_chunks: [],
    invalid_tool_calls: []
  ]
end

defmodule BeamWeaver.Core.Messages.AIChunk do
  @moduledoc false
  defstruct role: :assistant,
            content: "",
            id: nil,
            name: nil,
            metadata: %{},
            tool_calls: [],
            tool_call_chunks: [],
            invalid_tool_calls: []
end

defmodule BeamWeaver.Core.Messages do
  @moduledoc """
  Constructors for tool-call and message chunk structs.
  """

  alias BeamWeaver.Core.Messages.AIChunk
  alias BeamWeaver.Core.Messages.InvalidToolCall
  alias BeamWeaver.Core.Messages.ToolCall
  alias BeamWeaver.Core.Messages.ToolCallChunk

  def ai_chunk(content, opts \\ []),
    do: %AIChunk{
      content: content,
      id: opts[:id],
      name: opts[:name],
      metadata: opts[:metadata] || %{},
      tool_call_chunks: opts[:tool_call_chunks] || []
    }

  def tool_call(opts), do: struct(ToolCall, opts)
  def tool_call_chunk(opts), do: struct(ToolCallChunk, opts)
  def invalid_tool_call(opts), do: struct(InvalidToolCall, opts)

  @doc """
  Parses raw provider tool-call payloads into native tool-call structs.

  Parsing is best-effort: calls whose arguments are a valid JSON object become
  `ToolCall` structs, and calls with invalid arguments are kept as
  `InvalidToolCall` structs so the caller can report the problem.
  """
  @spec parse_tool_calls([map()]) ::
          {:ok, %{tool_calls: [ToolCall.t()], invalid_tool_calls: [InvalidToolCall.t()]}}
  def parse_tool_calls(raw_calls) when is_list(raw_calls) do
    BeamWeaver.Core.ToolCallParser.parse_raw_calls(raw_calls)
  end

  @doc """
  Parses raw provider streaming tool-call payloads into native chunk structs.
  """
  @spec parse_tool_call_chunks([map()]) :: {:ok, [ToolCallChunk.t()]}
  def parse_tool_call_chunks(raw_calls) when is_list(raw_calls) do
    BeamWeaver.Core.ToolCallParser.parse_raw_chunks(raw_calls)
  end
end
