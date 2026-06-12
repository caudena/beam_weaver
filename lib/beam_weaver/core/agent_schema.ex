defmodule BeamWeaver.Core.AgentAction do
  @moduledoc """
  Backwards-compatible agent action schema.

  BeamWeaver agents should normally be built with `BeamWeaver.Agent`, but this
  struct preserves LangChain's `AgentAction` data contract for interop and
  replay tooling.
  """

  alias BeamWeaver.Core.Message

  @enforce_keys [:tool, :tool_input, :log]
  defstruct [:tool, :tool_input, :log, type: "AgentAction"]

  @type t :: %__MODULE__{
          tool: String.t(),
          tool_input: String.t() | map(),
          log: String.t(),
          type: String.t()
        }

  @spec new(String.t(), String.t() | map(), String.t(), keyword()) :: t()
  def new(tool, tool_input, log, opts \\ []) do
    struct!(__MODULE__, Keyword.merge([tool: tool, tool_input: tool_input, log: log], opts))
  end

  @doc """
  Returns the LangChain serialization namespace retained for data interop.
  """
  @spec lc_namespace() :: [String.t()]
  def lc_namespace, do: ["langchain", "schema", "agent"]

  @spec serializable?() :: true
  def serializable?, do: true

  @doc """
  Converts the action into the assistant message implied by its log.
  """
  @spec messages(t()) :: [Message.t()]
  def messages(%__MODULE__{log: log}), do: [Message.assistant(log)]
end

defmodule BeamWeaver.Core.AgentActionMessageLog do
  @moduledoc """
  Agent action schema that stores the original chat-message log.
  """

  alias BeamWeaver.Core.AgentAction
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.Utils

  @enforce_keys [:tool, :tool_input, :log, :message_log]
  defstruct [:tool, :tool_input, :log, :message_log, type: "AgentActionMessageLog"]

  @type t :: %__MODULE__{
          tool: String.t(),
          tool_input: String.t() | map(),
          log: String.t(),
          message_log: [Message.t()],
          type: String.t()
        }

  @spec new(String.t(), String.t() | map(), String.t(), [term()], keyword()) :: t()
  def new(tool, tool_input, log, message_log, opts \\ []) do
    struct!(
      __MODULE__,
      Keyword.merge(
        [
          tool: tool,
          tool_input: tool_input,
          log: log,
          message_log: normalize_messages!(message_log)
        ],
        opts
      )
    )
  end

  @spec from_action(AgentAction.t(), [term()], keyword()) :: t()
  def from_action(%AgentAction{} = action, message_log, opts \\ []) do
    new(action.tool, action.tool_input, action.log, message_log, opts)
  end

  @spec lc_namespace() :: [String.t()]
  def lc_namespace, do: AgentAction.lc_namespace()

  @spec serializable?() :: true
  def serializable?, do: true

  @spec messages(t()) :: [Message.t()]
  def messages(%__MODULE__{message_log: message_log}), do: normalize_messages!(message_log)

  defp normalize_messages!(messages) do
    case Utils.convert_to_messages(messages) do
      {:ok, messages} -> messages
      {:error, error} -> raise ArgumentError, error.message
    end
  end
end

defmodule BeamWeaver.Core.AgentStep do
  @moduledoc """
  Result of executing an agent action.
  """

  alias BeamWeaver.Core.AgentAction
  alias BeamWeaver.Core.AgentActionMessageLog
  alias BeamWeaver.Core.Message

  @enforce_keys [:action, :observation]
  defstruct [:action, :observation]

  @type action :: AgentAction.t() | AgentActionMessageLog.t()
  @type t :: %__MODULE__{action: action(), observation: term()}

  @spec new(action(), term()) :: t()
  def new(action, observation), do: %__MODULE__{action: action, observation: observation}

  @doc """
  Converts the observation into the message shape LangChain would replay.

  Actions with a message log produce a function-style assistant message because
  the original prediction came from a chat model. Plain actions produce a user
  message containing the observation.
  """
  @spec messages(t()) :: [Message.t()]
  def messages(%__MODULE__{action: %AgentActionMessageLog{} = action, observation: observation}) do
    [
      Message.assistant(
        observation_content(observation),
        name: action.tool
      )
    ]
  end

  def messages(%__MODULE__{observation: observation}) do
    [Message.user(observation_content(observation))]
  end

  defp observation_content(observation) when is_binary(observation), do: observation

  defp observation_content(observation) do
    case BeamWeaver.JSON.encode(observation) do
      {:ok, encoded} -> encoded
      {:error, _error} -> inspect(observation)
    end
  end
end

defmodule BeamWeaver.Core.AgentFinish do
  @moduledoc """
  Final return value produced by an agent.
  """

  alias BeamWeaver.Core.AgentAction
  alias BeamWeaver.Core.Message

  @enforce_keys [:return_values, :log]
  defstruct [:return_values, :log, type: "AgentFinish"]

  @type t :: %__MODULE__{
          return_values: map(),
          log: String.t(),
          type: String.t()
        }

  @spec new(map(), String.t(), keyword()) :: t()
  def new(return_values, log, opts \\ []) do
    struct!(__MODULE__, Keyword.merge([return_values: return_values, log: log], opts))
  end

  @spec lc_namespace() :: [String.t()]
  def lc_namespace, do: AgentAction.lc_namespace()

  @spec serializable?() :: true
  def serializable?, do: true

  @spec messages(t()) :: [Message.t()]
  def messages(%__MODULE__{log: log}), do: [Message.assistant(log)]
end
