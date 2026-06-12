defmodule BeamWeaver.Tool.Schema do
  @moduledoc """
  Explicit tool schema helpers.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Tool.Schema.Fields
  alias BeamWeaver.Tool.Schema.Refs
  alias BeamWeaver.Tool.SchemaLike

  @doc """
  Converts a schema-like value into a JSON-schema-like map.

  This is the protocol-backed entry point used for broad, explicit schema
  conversion. It accepts already-shaped JSON schema maps, BeamWeaver field
  declarations, NimbleOptions-style specs, and Ecto-style schema modules.
  """
  @spec from(term()) :: {:ok, map()} | {:error, Error.t()}
  def from(schema_like), do: SchemaLike.to_schema(schema_like)

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

  @doc false
  defdelegate normalize_key(key), to: Fields

  @doc false
  defdelegate stringify_schema(map), to: Fields

  @doc false
  defdelegate from_nimble_options(opts), to: Fields

  @doc false
  defdelegate from_ecto_schema(module), to: Fields
end
