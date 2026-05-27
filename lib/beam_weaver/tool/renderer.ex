defmodule BeamWeaver.Tool.Renderer do
  @moduledoc """
  Provider-facing rendering helpers for BeamWeaver tools.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Tool.Schema

  @provider_name ~r/^[A-Za-z0-9_-]{1,64}$/

  @doc """
  Renders a readable tool description.
  """
  @spec description(term()) :: String.t()
  def description(tool) do
    "#{Tool.name(tool)}: #{Tool.description(tool)}"
  end

  @doc """
  Renders tool names and descriptions as plain text.
  """
  @spec render_text_description([term()]) :: String.t()
  def render_text_description(tools) when is_list(tools) do
    Enum.map_join(tools, "\n", &"#{Tool.name(&1)} - #{Tool.description(&1)}")
  end

  @doc """
  Renders tool names, descriptions, and public argument schemas as plain text.
  """
  @spec render_text_description_and_args([term()]) :: String.t()
  def render_text_description_and_args(tools) when is_list(tools) do
    Enum.map_join(tools, "\n", fn tool ->
      args = tool |> Tool.args() |> inspect(limit: :infinity)
      "#{Tool.name(tool)} - #{Tool.description(tool)}, args: #{args}"
    end)
  end

  @doc """
  Renders an OpenAI function declaration.
  """
  @spec openai_function(term(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def openai_function(tool, opts \\ []) do
    with :ok <- validate_provider_name(Tool.name(tool), :openai) do
      with {:ok, parameters} <-
             tool
             |> Tool.input_schema()
             |> BeamWeaver.MapShape.stringify_keys()
             |> Schema.dereference_refs() do
        function = %{
          "name" => Tool.name(tool),
          "description" => Tool.description(tool),
          "parameters" => maybe_strict_schema(parameters, Keyword.get(opts, :strict))
        }

        function =
          if Keyword.has_key?(opts, :strict),
            do: Map.put(function, "strict", Keyword.fetch!(opts, :strict)),
            else: function

        {:ok, function}
      end
    end
  end

  @doc """
  Renders an OpenAI Responses tool declaration.
  """
  @spec openai_tool(term(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def openai_tool(tool, opts \\ []) do
    with {:ok, function} <- openai_function(tool, opts) do
      {:ok, Map.put(function, "type", "function")}
    end
  end

  @doc """
  Raises on invalid OpenAI tool rendering.
  """
  @spec openai_tool!(term(), keyword()) :: map()
  def openai_tool!(tool, opts \\ []) do
    case openai_tool(tool, opts) do
      {:ok, rendered} -> rendered
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @doc """
  Renders an Anthropic custom tool declaration.
  """
  @spec anthropic_tool(term(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def anthropic_tool(tool, opts \\ []) do
    with :ok <- validate_provider_name(Tool.name(tool), :anthropic),
         {:ok, input_schema} <-
           tool
           |> Tool.input_schema()
           |> BeamWeaver.MapShape.stringify_keys()
           |> Schema.dereference_refs() do
      tool =
        %{
          "name" => Tool.name(tool),
          "description" => Tool.description(tool),
          "input_schema" => maybe_strict_schema(input_schema, Keyword.get(opts, :strict))
        }
        |> maybe_put_render_opt("strict", opts, :strict)
        |> maybe_put_render_opt("cache_control", opts, :cache_control)
        |> maybe_put_render_opt("defer_loading", opts, :defer_loading)
        |> maybe_put_render_opt("input_examples", opts, :input_examples)
        |> maybe_put_render_opt("allowed_callers", opts, :allowed_callers)

      {:ok, tool}
    end
  end

  @doc """
  Raises on invalid Anthropic tool rendering.
  """
  @spec anthropic_tool!(term(), keyword()) :: map()
  def anthropic_tool!(tool, opts \\ []) do
    case anthropic_tool(tool, opts) do
      {:ok, rendered} -> rendered
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @doc """
  Validates that a tool name can be sent to a provider.
  """
  @spec validate_provider_name(String.t(), atom()) :: :ok | {:error, Error.t()}
  def validate_provider_name(name, provider) when is_binary(name) do
    if Regex.match?(@provider_name, name) do
      :ok
    else
      {:error,
       Error.new(:invalid_tool_name, "tool name is not valid for provider", %{
         name: name,
         provider: provider
       })}
    end
  end

  def validate_provider_name(name, provider) do
    {:error,
     Error.new(:invalid_tool_name, "tool name must be a string", %{
       name: inspect(name),
       provider: provider
     })}
  end

  defp maybe_strict_schema(schema, true), do: strict_schema(schema)
  defp maybe_strict_schema(schema, _strict), do: schema

  defp maybe_put_render_opt(map, provider_key, opts, opt_key) do
    if Keyword.has_key?(opts, opt_key) do
      Map.put(map, provider_key, Keyword.fetch!(opts, opt_key))
    else
      map
    end
  end

  defp strict_schema(schema) when is_map(schema) do
    schema
    |> strict_schema_children()
    |> close_object_schema()
  end

  defp strict_schema(value), do: value

  defp strict_schema_children(schema) do
    Enum.reduce(
      ["properties", "items", "anyOf", "oneOf", "allOf", "$defs", "definitions"],
      schema,
      fn
        key, acc when key in ["properties", "$defs", "definitions"] ->
          Map.update(acc, key, nil, fn
            nil ->
              nil

            children when is_map(children) ->
              Map.new(children, fn {name, child} -> {name, strict_schema(child)} end)

            children ->
              children
          end)

        key, acc when key in ["anyOf", "oneOf", "allOf"] ->
          Map.update(acc, key, nil, fn
            nil -> nil
            children when is_list(children) -> Enum.map(children, &strict_schema/1)
            children -> children
          end)

        "items", acc ->
          Map.update(acc, "items", nil, fn
            nil -> nil
            children when is_list(children) -> Enum.map(children, &strict_schema/1)
            child -> strict_schema(child)
          end)
      end
    )
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp close_object_schema(%{"properties" => properties} = schema) when is_map(properties) do
    schema
    |> Map.put("additionalProperties", Map.get(schema, "additionalProperties", false))
    |> put_strict_required(properties)
  end

  defp close_object_schema(%{"type" => type} = schema) when type in ["object", :object] do
    Map.put(schema, "additionalProperties", Map.get(schema, "additionalProperties", false))
  end

  defp close_object_schema(%{"type" => types} = schema) when is_list(types) do
    if Enum.any?(types, &(&1 in ["object", :object])) do
      Map.put(schema, "additionalProperties", Map.get(schema, "additionalProperties", false))
    else
      schema
    end
  end

  defp close_object_schema(schema), do: schema

  defp put_strict_required(schema, properties) when map_size(properties) == 0, do: schema

  defp put_strict_required(schema, properties) do
    existing = Map.get(schema, "required", [])
    property_names = properties |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()

    required =
      existing
      |> Enum.map(&to_string/1)
      |> Kernel.++(property_names)
      |> Enum.uniq()

    Map.put(schema, "required", required)
  end
end
