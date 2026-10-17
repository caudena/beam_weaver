defmodule BeamWeaver.Serialization.Codec do
  @moduledoc """
  Safe serialization codec behaviour.
  """

  @callback dump(term(), keyword()) :: {:ok, binary()} | {:error, BeamWeaver.Core.Error.t()}
  @callback load(binary(), keyword()) :: {:ok, term()} | {:error, BeamWeaver.Core.Error.t()}
end

defmodule BeamWeaver.Serialization.Registry do
  @moduledoc """
  Explicit decode allowlist for tagged BeamWeaver structs.

  Only the structs registered here are rebuilt when a value loads. A saved
  struct whose tag isn't registered, or whose module is no longer available,
  loads as a map of its fields with string keys.
  """

  defstruct types: %{
              "beam_weaver.core.document" => BeamWeaver.Core.Document,
              "beam_weaver.core.message" => BeamWeaver.Core.Message,
              "beam_weaver.core.content_block.text" => BeamWeaver.Core.ContentBlock.Text,
              "beam_weaver.core.content_block.plain_text" => BeamWeaver.Core.ContentBlock.PlainText,
              "beam_weaver.core.content_block.image" => BeamWeaver.Core.ContentBlock.Image,
              "beam_weaver.core.content_block.audio" => BeamWeaver.Core.ContentBlock.Audio,
              "beam_weaver.core.content_block.file" => BeamWeaver.Core.ContentBlock.File,
              "beam_weaver.core.content_block.video" => BeamWeaver.Core.ContentBlock.Video,
              "beam_weaver.core.content_block.reasoning" => BeamWeaver.Core.ContentBlock.Reasoning,
              "beam_weaver.core.content_block.citation" => BeamWeaver.Core.ContentBlock.Citation,
              "beam_weaver.core.content_block.tool_result" => BeamWeaver.Core.ContentBlock.ToolResult,
              "beam_weaver.core.content_block.unknown" => BeamWeaver.Core.ContentBlock.Unknown,
              "beam_weaver.core.tool_result" => BeamWeaver.Core.ToolResult,
              "beam_weaver.core.messages.tool_call" => BeamWeaver.Core.Messages.ToolCall,
              "beam_weaver.core.messages.tool_call_chunk" => BeamWeaver.Core.Messages.ToolCallChunk,
              "beam_weaver.core.messages.invalid_tool_call" => BeamWeaver.Core.Messages.InvalidToolCall,
              "beam_weaver.agent.usage" => BeamWeaver.Agent.Usage,
              "beam_weaver.agent.subagent.async_task" => BeamWeaver.Agent.Subagent.AsyncTask,
              "beam_weaver.filesystem.file_data" => BeamWeaver.Filesystem.FileData,
              "beam_weaver.graph.command" => BeamWeaver.Graph.Command,
              "beam_weaver.graph.send" => BeamWeaver.Graph.Send,
              "beam_weaver.graph.interrupt" => BeamWeaver.Graph.Interrupt,
              "beam_weaver.graph.resume" => BeamWeaver.Graph.Resume,
              "beam_weaver.graph.overwrite" => BeamWeaver.Graph.Overwrite,
              "beam_weaver.graph.messages.remove" => BeamWeaver.Graph.Messages.Remove,
              "beam_weaver.graph.execution.task_request" => BeamWeaver.Graph.Execution.TaskRequest,
              "beam_weaver.graph.execution.node_output" => BeamWeaver.Graph.Execution.NodeOutput,
              "beam_weaver.graph.execution_info" => BeamWeaver.Graph.ExecutionInfo,
              "beam_weaver.graph.channels.delta_snapshot" => BeamWeaver.Graph.Channels.DeltaSnapshot,
              "beam_weaver.core.error" => BeamWeaver.Core.Error,
              "beam_weaver.typesafe.response" => BeamWeaver.TypeSafe.Response,
              "beam_weaver.typesafe.choice_answer" => BeamWeaver.TypeSafe.ChoiceAnswer,
              "beam_weaver.typesafe.score_answer" => BeamWeaver.TypeSafe.ScoreAnswer,
              "beam_weaver.typesafe.noul_answer" => BeamWeaver.TypeSafe.NoulAnswer,
              "beam_weaver.openai.decisions.response" => BeamWeaver.OpenAI.Decisions.Response,
              "beam_weaver.openai.decisions.predicate_answer" => BeamWeaver.OpenAI.Decisions.PredicateAnswer,
              "beam_weaver.openai.decisions.choice_answer" => BeamWeaver.OpenAI.Decisions.ChoiceAnswer,
              "beam_weaver.openai.decisions.score_answer" => BeamWeaver.OpenAI.Decisions.ScoreAnswer,
              "beam_weaver.openai.decisions.refusal_answer" => BeamWeaver.OpenAI.Decisions.RefusalAnswer,
              "beam_weaver.timeout_policy" => BeamWeaver.TimeoutPolicy,
              "beam_weaver.tracing.run" => BeamWeaver.Tracing.Run
            }

  @type t :: %__MODULE__{types: %{String.t() => module()}}

  def new(opts \\ [])

  def new(:core), do: %__MODULE__{}

  def new(:messages),
    do: %__MODULE__{types: %{"beam_weaver.core.message" => BeamWeaver.Core.Message}}

  def new(opts) do
    extra = Keyword.get(opts, :types, %{})
    %__MODULE__{types: Map.merge(%__MODULE__{}.types, extra)}
  end

  @spec tags(t()) :: [String.t()]
  def tags(%__MODULE__{} = registry), do: registry.types |> Map.keys() |> Enum.sort()

  @spec merge(t(), t() | map()) :: t()
  def merge(%__MODULE__{} = registry, %__MODULE__{} = other),
    do: %__MODULE__{types: Map.merge(registry.types, other.types)}

  def merge(%__MODULE__{} = registry, types) when is_map(types),
    do: %__MODULE__{types: Map.merge(registry.types, types)}

  @spec register(t(), String.t(), module()) :: t()
  def register(%__MODULE__{} = registry, tag, module) when is_binary(tag) and is_atom(module),
    do: %__MODULE__{types: Map.put(registry.types, tag, module)}

  def tag_for(%__MODULE__{} = registry, module) do
    Enum.find_value(registry.types, fn {tag, registered} ->
      if registered == module, do: tag
    end)
  end

  def module_for(%__MODULE__{} = registry, tag), do: Map.get(registry.types, tag)
end

defmodule BeamWeaver.Serialization.Config do
  @moduledoc """
  Explicit serialization configuration for durable adapters.

  `:codec` and `:registry` select the codec and the structs it may load. Every
  other option, such as `:encryption_key` for
  `BeamWeaver.Serialization.Encrypted`, is kept in `opts` and passed to the
  codec. `inspect/1` doesn't show them.
  """

  @derive {Inspect, only: [:codec, :registry]}
  defstruct codec: BeamWeaver.Serialization.JSON,
            registry: BeamWeaver.Serialization.Registry.new(),
            opts: []

  @type t :: %__MODULE__{
          codec: module(),
          registry: BeamWeaver.Serialization.Registry.t(),
          opts: keyword()
        }

  @spec new(keyword() | map() | t() | nil) :: t()
  def new(nil), do: %__MODULE__{}
  def new(%__MODULE__{} = config), do: config
  def new(opts) when is_map(opts), do: opts |> Map.to_list() |> new()

  def new(opts) when is_list(opts) do
    {codec, opts} = Keyword.pop(opts, :codec, BeamWeaver.Serialization.JSON)
    {registry, opts} = Keyword.pop_lazy(opts, :registry, &BeamWeaver.Serialization.Registry.new/0)
    %__MODULE__{codec: codec, registry: registry, opts: opts}
  end

  @doc false
  @spec codec_opts(t()) :: keyword()
  def codec_opts(%__MODULE__{} = config), do: Keyword.put(config.opts, :registry, config.registry)
end

defmodule BeamWeaver.Serialization.JSON do
  @moduledoc """
  JSON serialization that loads back the values it saved.

  Atoms, tuples, binaries that aren't UTF-8, dates and times, and the structs
  in the `BeamWeaver.Serialization.Registry` are tagged. Map keys keep their
  type at any depth: a JSON object names its atom keys under
  `"__beam_weaver_atom_keys__"`, and a map with other keys, such as integers,
  is saved as a list of entries. Loading creates no atoms, so an atom or an
  atom key that doesn't exist in the running system comes back as a string.
  A struct that can't be rebuilt, because its tag isn't in the registry or
  its module is gone, comes back as a map of its fields. Each such atom and
  tag is logged as a warning the first time it loads.
  """

  @behaviour BeamWeaver.Serialization.Codec

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Serialization.JSON.Decoder
  alias BeamWeaver.Serialization.JSON.Encoder
  alias BeamWeaver.Serialization.Registry

  @impl true
  def dump(value, opts \\ []) do
    registry = Keyword.get(opts, :registry, Registry.new())

    with {:ok, encoded} <- Encoder.encode(value, registry),
         {:ok, json} <- BeamWeaver.JSON.encode(encoded) do
      {:ok, json}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, Error.new(:serialization_error, "JSON encoding failed", %{reason: inspect(reason)})}
    end
  end

  @impl true
  def load(binary, opts \\ []) when is_binary(binary) do
    registry = Keyword.get(opts, :registry, Registry.new())

    with {:ok, decoded} <- BeamWeaver.JSON.decode(binary),
         {:ok, value} <- Decoder.decode(decoded, registry) do
      {:ok, value}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, Error.new(:serialization_error, "JSON decoding failed", %{reason: inspect(reason)})}
    end
  end
end

defmodule BeamWeaver.Serialization do
  @moduledoc """
  Safe public serialization facade.
  """

  alias BeamWeaver.Serialization.Config

  def dump(value, opts \\ []) do
    config = config(opts)
    config.codec.dump(value, Config.codec_opts(config))
  end

  def load(binary, opts \\ []) do
    config = config(opts)
    config.codec.load(binary, Config.codec_opts(config))
  end

  @doc """
  Encodes a value into the JSON-compatible representation used by the configured codec.

  This is the native BeamWeaver equivalent of a "dump to data" operation: callers get
  plain maps/lists/scalars that can be inspected, stored in JSONB, or passed through
  another JSON encoder without enabling arbitrary term loading.
  """
  def dump_value(value, opts \\ []) do
    with {:ok, binary} <- dump(value, opts) do
      BeamWeaver.JSON.decode(binary)
    end
  end

  @doc """
  Decodes a JSON-compatible value through the same allowlisted codec boundary as `load/2`.
  """
  def load_value(value, opts \\ []) do
    with {:ok, binary} <- BeamWeaver.JSON.encode(value) do
      load(binary, opts)
    end
  end

  defp config(opts) do
    opts
    |> Keyword.get(:serialization, opts)
    |> Config.new()
  end
end
