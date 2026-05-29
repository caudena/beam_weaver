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
              "beam_weaver.graph.command" => BeamWeaver.Graph.Command,
              "beam_weaver.graph.send" => BeamWeaver.Graph.Send,
              "beam_weaver.graph.interrupt" => BeamWeaver.Graph.Interrupt,
              "beam_weaver.graph.resume" => BeamWeaver.Graph.Resume,
              "beam_weaver.graph.overwrite" => BeamWeaver.Graph.Overwrite,
              "beam_weaver.graph.channels.delta_snapshot" => BeamWeaver.Graph.Channels.DeltaSnapshot,
              "beam_weaver.core.error" => BeamWeaver.Core.Error,
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
  """

  defstruct codec: BeamWeaver.Serialization.JSON,
            registry: BeamWeaver.Serialization.Registry.new()

  @type t :: %__MODULE__{
          codec: module(),
          registry: BeamWeaver.Serialization.Registry.t()
        }

  @spec new(keyword() | map() | t() | nil) :: t()
  def new(nil), do: %__MODULE__{}
  def new(%__MODULE__{} = config), do: config
  def new(opts) when is_map(opts), do: opts |> Map.to_list() |> new()

  def new(opts) when is_list(opts) do
    %__MODULE__{
      codec: Keyword.get(opts, :codec, BeamWeaver.Serialization.JSON),
      registry: Keyword.get(opts, :registry, BeamWeaver.Serialization.Registry.new())
    }
  end
end

defmodule BeamWeaver.Serialization.JSON do
  @moduledoc """
  JSON/type-tagged portable serialization.
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

  def dump(value, opts \\ []) do
    config = config(opts)
    config.codec.dump(value, Keyword.put(opts, :registry, config.registry))
  end

  def load(binary, opts \\ []) do
    config = config(opts)
    config.codec.load(binary, Keyword.put(opts, :registry, config.registry))
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

  @doc false
  def dump_json_value(value, opts \\ []), do: dump_value(value, opts)

  @doc false
  def load_json_value(value, opts \\ []), do: load_value(value, opts)

  defp config(opts) do
    opts
    |> Keyword.get(:serialization, opts)
    |> BeamWeaver.Serialization.Config.new()
  end
end
