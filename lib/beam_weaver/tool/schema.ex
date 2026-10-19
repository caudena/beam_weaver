defmodule BeamWeaver.Tool.Schema do
  @moduledoc """
  Explicit tool schema helpers.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Tool.Schema.Fields
  alias BeamWeaver.Tool.Schema.Refs

  @doc """
  Converts a schema-like value into a JSON-schema-like map.

  Accepts JSON schema maps, BeamWeaver field declarations
  (`{name, type}` or `{name, type, opts}`), NimbleOptions-style specs, modules
  defining `__beam_weaver_schema__/0`, Ecto-style schema modules, and structs
  of those modules.
  """
  @spec from(term()) :: {:ok, map()} | {:error, Error.t()}
  def from(%module{}), do: from(module)
  def from(map) when is_map(map), do: {:ok, BeamWeaver.MapShape.stringify_keys(map)}
  def from([]), do: {:ok, Fields.from_fields([])}

  def from(list) when is_list(list) do
    cond do
      Enum.all?(list, &nimble_option?/1) ->
        Fields.from_nimble_options(list)

      Enum.all?(list, &field_decl?/1) ->
        {:ok, Fields.from_fields(list)}

      true ->
        {:error, Error.new(:invalid_tool_schema, "list schema must be field declarations or NimbleOptions specs")}
    end
  end

  def from(module) when is_atom(module) do
    if BeamWeaver.Behaviour.exported?(module, :__beam_weaver_schema__, 0),
      do: from(module.__beam_weaver_schema__()),
      else: Fields.from_ecto_schema(module)
  end

  def from(value),
    do:
      {:error, Error.new(:invalid_tool_schema, "value cannot be converted to a tool schema", %{value: inspect(value)})}

  defp field_decl?({name, _type}) when is_atom(name) or is_binary(name), do: true
  defp field_decl?({name, _type, opts}) when (is_atom(name) or is_binary(name)) and is_list(opts), do: true
  defp field_decl?(_entry), do: false

  defp nimble_option?({name, opts}) when (is_atom(name) or is_binary(name)) and is_list(opts),
    do: Keyword.keyword?(opts) and Keyword.has_key?(opts, :type)

  defp nimble_option?(_entry), do: false

  @doc """
  Builds a JSON-schema object from field declarations.
  """
  @spec from_fields([{atom() | String.t(), term(), keyword()}]) :: map()
  defdelegate from_fields(fields), to: Fields

  @doc """
  Converts an Elixir type declaration into a JSON-schema-like map.
  """
  @spec type_schema(term()) :: map()
  defdelegate type_schema(type), to: Fields

  @doc """
  Dereferences local JSON Schema `$ref` entries using JSON Pointer fragments.

  The helper returns tagged results instead of raising. It intentionally handles
  only local fragments (`#/...`) because remote schema fetching is a transport
  concern and should stay outside the tool-schema boundary.
  """
  @spec dereference_refs(term(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  defdelegate dereference_refs(schema, opts \\ []), to: Refs

  @doc """
  Removes JSON Schema `title` annotations while preserving fields named `title`.
  """
  @spec remove_titles(term()) :: term()
  defdelegate remove_titles(schema), to: Refs
end
