defmodule BeamWeaver.Core.Messages.System do
  @moduledoc false
  defstruct [:content, :id, :name, metadata: %{}]
end

defmodule BeamWeaver.Core.Messages.User do
  @moduledoc false
  defstruct [:content, :id, :name, metadata: %{}]
end

defmodule BeamWeaver.Core.Messages.Assistant do
  @moduledoc false
  defstruct [:content, :id, :name, metadata: %{}, tool_calls: []]
end

defmodule BeamWeaver.Core.Messages.Tool do
  @moduledoc false
  defstruct [:content, :tool_call_id, :id, :name, metadata: %{}]
end

defmodule BeamWeaver.Core.Messages.Function do
  @moduledoc false
  defstruct [:content, :id, :name, metadata: %{}]
end

defmodule BeamWeaver.Core.Messages.Chat do
  @moduledoc false
  defstruct [:role, :content, :id, :name, metadata: %{}]
end

defmodule BeamWeaver.Core.Messages.ToolCall do
  @moduledoc "Normalized model tool call."
  defstruct [:id, :provider_id, :call_id, :name, args: %{}, type: :tool_call]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          provider_id: String.t() | nil,
          call_id: String.t() | nil,
          name: String.t() | nil,
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

defmodule BeamWeaver.Core.Messages.ToolChunk do
  @moduledoc false
  defstruct role: :tool,
            content: "",
            tool_call_id: nil,
            id: nil,
            name: nil,
            metadata: %{}
end

defmodule BeamWeaver.Core.Messages.FunctionChunk do
  @moduledoc false
  defstruct role: :function,
            content: "",
            id: nil,
            name: nil,
            metadata: %{}
end

defmodule BeamWeaver.Core.Messages do
  @moduledoc """
  Constructors for typed message and chunk structs.
  """

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.AIChunk
  alias BeamWeaver.Core.Messages.Assistant
  alias BeamWeaver.Core.Messages.Chat
  alias BeamWeaver.Core.Messages.Function
  alias BeamWeaver.Core.Messages.InvalidToolCall
  alias BeamWeaver.Core.Messages.System
  alias BeamWeaver.Core.Messages.Tool
  alias BeamWeaver.Core.Messages.ToolCall
  alias BeamWeaver.Core.Messages.ToolCallChunk
  alias BeamWeaver.Core.Messages.User

  def system(content, opts \\ []),
    do: %System{
      content: content,
      id: opts[:id],
      name: opts[:name],
      metadata: opts[:metadata] || %{}
    }

  def user(content, opts \\ []),
    do: %User{
      content: content,
      id: opts[:id],
      name: opts[:name],
      metadata: opts[:metadata] || %{}
    }

  def assistant(content, opts \\ []),
    do: %Assistant{
      content: content,
      id: opts[:id],
      name: opts[:name],
      metadata: opts[:metadata] || %{},
      tool_calls: opts[:tool_calls] || []
    }

  def tool(content, opts \\ []),
    do: %Tool{
      content: content,
      tool_call_id: opts[:tool_call_id],
      id: opts[:id],
      name: opts[:name],
      metadata: opts[:metadata] || %{}
    }

  def function(content, opts \\ []),
    do: %Function{
      content: content,
      id: opts[:id],
      name: opts[:name],
      metadata: opts[:metadata] || %{}
    }

  def chat(role, content, opts \\ []),
    do: %Chat{
      role: role,
      content: content,
      id: opts[:id],
      name: opts[:name],
      metadata: opts[:metadata] || %{}
    }

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

  This is the BeamWeaver-native equivalent of LangChain's best-effort raw tool
  parser: valid JSON object arguments become `ToolCall` structs, and invalid
  arguments are preserved as `InvalidToolCall` structs for caller feedback.
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

  def to_message(%System{} = message),
    do:
      Message.system(message.content,
        id: message.id,
        name: message.name,
        metadata: message.metadata
      )

  def to_message(%User{} = message),
    do:
      Message.user(message.content,
        id: message.id,
        name: message.name,
        metadata: message.metadata
      )

  def to_message(%Assistant{} = message),
    do:
      Message.assistant(message.content,
        id: message.id,
        name: message.name,
        metadata: message.metadata,
        tool_calls: message.tool_calls
      )

  def to_message(%Tool{} = message),
    do:
      Message.tool(message.content,
        id: message.id,
        name: message.name,
        metadata: message.metadata,
        tool_call_id: message.tool_call_id
      )

  def to_message(%Function{} = message),
    do:
      Message.assistant(message.content,
        id: message.id,
        name: message.name,
        metadata: message.metadata || %{}
      )

  def to_message(%Chat{} = message),
    do:
      Message.user(message.content,
        id: message.id,
        name: message.name,
        metadata: generic_role_metadata(message.role, message.metadata)
      )

  def to_message(%Message{} = message), do: message

  defp generic_role_metadata(_role, metadata), do: metadata || %{}
end
