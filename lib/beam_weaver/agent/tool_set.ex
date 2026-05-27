defmodule BeamWeaver.Agent.ToolSet do
  @moduledoc """
  Scoped tool authority for one agent model/tool step.

  A `ToolSet` is stored in private graph state after the model node chooses the
  effective tools for a turn. The following validation/tool node reads the same
  set, so dynamic middleware cannot expose one tool schema to the model and
  execute a different static registry afterwards.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Tool

  defstruct tools: %{}, order: [], source: :static, metadata: %{}

  @type t :: %__MODULE__{
          tools: %{String.t() => term()},
          order: [String.t()],
          source: atom(),
          metadata: map()
        }

  @spec new([term()], keyword()) :: t()
  def new(tools \\ [], opts \\ []) do
    entries = tool_entries(tools)

    %__MODULE__{
      tools: Map.new(entries),
      order: Enum.map(entries, &elem(&1, 0)),
      source: Keyword.get(opts, :source, :static),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @spec add(t(), [term()], keyword()) :: t()
  def add(%__MODULE__{} = tool_set, tools, opts \\ []) do
    entries = tool_entries(tools)
    incoming = Map.new(entries)
    merged = Map.merge(tool_set.tools, incoming)
    new_names = entries |> Enum.map(&elem(&1, 0)) |> Enum.reject(&(&1 in tool_set.order))

    %{
      tool_set
      | tools: merged,
        order: tool_set.order ++ new_names,
        source: Keyword.get(opts, :source, tool_set.source),
        metadata: Map.merge(tool_set.metadata, Keyword.get(opts, :metadata, %{}))
    }
  end

  @spec filter(t(), (term() -> boolean())) :: t()
  def filter(%__MODULE__{} = tool_set, fun) when is_function(fun, 1) do
    tools = Map.filter(tool_set.tools, fn {_name, tool} -> fun.(tool) end)
    %{tool_set | tools: tools, order: Enum.filter(tool_set.order, &Map.has_key?(tools, &1))}
  end

  @spec list(t() | nil) :: [term()]
  def list(%__MODULE__{tools: tools, order: order}) do
    ordered =
      Enum.flat_map(order, fn name ->
        if Map.has_key?(tools, name), do: [tools[name]], else: []
      end)

    extras = tools |> Map.drop(order) |> Map.values()
    ordered ++ extras
  end

  def list(nil), do: []

  @spec names(t() | nil) :: [String.t()]
  def names(%__MODULE__{} = tool_set), do: Enum.map(list(tool_set), &Tool.name/1)
  def names(nil), do: []

  @spec get(t() | nil, String.t()) :: term() | nil
  def get(%__MODULE__{tools: tools}, name), do: Map.get(tools, to_string(name))
  def get(nil, _name), do: nil

  @spec from_state(term()) :: t() | nil
  def from_state(%{tool_set: %__MODULE__{} = tool_set}), do: tool_set
  def from_state(%{"tool_set" => %__MODULE__{} = tool_set}), do: tool_set
  def from_state(_state), do: nil

  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = tool_set) do
    tool_set.tools
    |> Map.values()
    |> Enum.reduce_while(:ok, fn tool, :ok ->
      case validate_tool(tool) do
        :ok -> {:cont, :ok}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp validate_tool(tool) do
    name = Tool.name(tool)
    schema = Tool.input_schema(tool)

    cond do
      not is_binary(name) or name == "" ->
        {:error, Error.new(:invalid_tool, "tool name is required")}

      not is_map(schema) ->
        {:error, Error.new(:invalid_tool, "tool input_schema must be a map", %{tool: name})}

      true ->
        :ok
    end
  rescue
    exception ->
      {:error,
       Error.new(:invalid_tool, "tool declaration is invalid", %{
         exception: Exception.message(exception)
       })}
  end

  defp tool_entries(tools) do
    tools
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn tool -> {Tool.name(tool), tool} end)
  end
end
