defmodule BeamWeaver.Tool.Converter do
  @moduledoc """
  Converts BeamWeaver tool-like values into executable `%BeamWeaver.Core.Tool{}` values.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Messages.Serialization
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Result
  alias BeamWeaver.Runnable
  alias BeamWeaver.ToolKit

  @doc """
  Converts one tool-like value into `%BeamWeaver.Core.Tool{}`.
  """
  @spec to_tool(term(), keyword()) :: {:ok, Tool.t()} | {:error, Error.t()}
  def to_tool(tool, opts \\ [])

  def to_tool(%Tool{} = tool, _opts), do: {:ok, tool}

  def to_tool(module, opts) when is_atom(module) do
    cond do
      BeamWeaver.Behaviour.exported?(module, :__beam_weaver_tool__, 0) ->
        to_tool(struct(module), opts)

      Tool.implemented_by?(module) ->
        to_tool_from_behaviour(module, opts)

      ToolKit.implemented_by?(module) ->
        {:error, Error.new(:invalid_tool, "toolkits must be converted with to_tools/2")}

      true ->
        {:error, Error.new(:invalid_tool, "module is not a BeamWeaver tool", %{module: module})}
    end
  end

  def to_tool(%module{} = tool, opts) do
    cond do
      Tool.implemented_by?(module) ->
        to_tool_from_behaviour(tool, opts)

      BeamWeaver.Behaviour.exported?(module, :invoke, 3) ->
        runnable_to_tool(tool, opts)

      true ->
        {:error, Error.new(:invalid_tool, "value is not a BeamWeaver tool")}
    end
  end

  def to_tool(fun, opts) when is_function(fun, 2) do
    opts
    |> Keyword.put(:handler, fun)
    |> Tool.from_function()
  end

  def to_tool(%{"type" => "function", "function" => %{"name" => _name}} = schema, _opts) do
    provider_schema_tool(schema)
  end

  def to_tool(tool, opts) when is_map(tool) do
    if Map.has_key?(tool, :name) or Map.has_key?(tool, "name") do
      provider_schema_tool(tool)
    else
      runnable_to_tool(tool, opts)
    end
  end

  def to_tool(tool, _opts),
    do: {:error, Error.new(:invalid_tool, "unsupported tool value", %{tool: inspect(tool)})}

  @doc """
  Converts tools and toolkits into a flat list of `%Tool{}` values.
  """
  @spec to_tools([term()] | term(), keyword()) :: {:ok, [Tool.t()]} | {:error, Error.t()}
  def to_tools(tools, opts \\ []) do
    with {:ok, tools} <- tools |> List.wrap() |> Result.flat_traverse(&convert_one_or_many(&1, opts)) do
      reject_duplicate_names(tools)
    end
  end

  defp convert_one_or_many({module, tool_opts}, opts) when is_atom(module) and is_list(tool_opts) do
    convert_one_or_many(module, Keyword.merge(opts, tool_opts))
  end

  defp convert_one_or_many(tool, opts) do
    if is_atom(tool) and ToolKit.implemented_by?(tool) do
      with {:ok, tools} <- ToolKit.tools(tool, opts), do: to_tools(tools, opts)
    else
      with {:ok, tool} <- to_tool(tool, opts), do: {:ok, [tool]}
    end
  end

  defp to_tool_from_behaviour(tool, opts) do
    Tool.from_function(
      name: Tool.name(tool),
      description: Tool.description(tool),
      input_schema: Tool.raw_input_schema(tool),
      injected: Tool.injected(tool),
      return_direct: Tool.return_direct(tool),
      response_format: Tool.response_format(tool),
      output_schema: Tool.output_schema(tool),
      tags: Tool.tags(tool),
      metadata: Tool.metadata(tool),
      provider_opts: Tool.provider_opts(tool),
      handler: fn input, call_opts ->
        call_opts =
          opts
          |> Keyword.merge(call_opts)
          |> Keyword.put(:trace?, false)

        Tool.invoke(tool, input, call_opts)
      end
    )
  end

  defp runnable_to_tool(runnable, opts) do
    with {:ok, name} <- required_opt(opts, :name),
         {:ok, description} <- required_opt(opts, :description),
         {:ok, input_schema} <- required_opt(opts, :input_schema) do
      Tool.from_function(
        name: name,
        description: description,
        input_schema: input_schema,
        output_schema: Keyword.get(opts, :output_schema),
        handler: fn input, call_opts -> Runnable.invoke(runnable, input, call_opts) end
      )
    end
  end

  defp provider_schema_tool(%{"type" => "function", "function" => function}) do
    provider_schema_tool(function)
  end

  defp provider_schema_tool(schema) when is_map(schema) do
    schema = Serialization.stringify_value(schema)
    name = schema["name"]
    description = schema["description"] || ""
    input_schema = schema["parameters"] || %{"type" => "object", "properties" => %{}}

    Tool.from_function(
      name: name,
      description: description,
      input_schema: input_schema,
      metadata: %{"provider_schema" => schema},
      handler: fn _input, _opts ->
        {:error, Error.new(:tool_error, "provider schema tools are declarations only")}
      end
    )
  end

  defp required_opt(opts, key) do
    with :error <- Keyword.fetch(opts, key), do: {:error, Error.new(:invalid_tool, "runnable tool requires #{key}")}
  end

  defp reject_duplicate_names(tools) do
    names = Enum.map(tools, &Tool.name/1)
    duplicates = names -- Enum.uniq(names)

    case Enum.uniq(duplicates) do
      [] ->
        {:ok, tools}

      duplicates ->
        {:error, Error.new(:duplicate_tool, "duplicate tool names", %{names: duplicates})}
    end
  end
end
