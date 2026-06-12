defmodule BeamWeaver.Migrations.Postgres.Util do
  @moduledoc false

  def qualify(prefix, name) do
    case prefix do
      nil -> quote_name(name)
      false -> quote_name(name)
      "" -> quote_name(name)
      prefix -> quote_name(prefix) <> "." <> quote_name(name)
    end
  end

  def regclass(prefix, name), do: qualify(prefix, name)

  def quote_name(name) do
    name
    |> to_string()
    |> String.split(".", trim: true)
    |> Enum.map_join(".", &~s("#{String.replace(&1, "\"", "\"\"")}"))
  end

  def index(_prefix, table, suffix), do: quote_name(index_name(table, suffix))

  def index_name(table, suffix) do
    base =
      table
      |> to_string()
      |> String.split(".")
      |> List.last()
      |> String.replace(~r/[^A-Za-z0-9_]/, "_")

    "#{base}_#{suffix}"
  end

  def escaped_comment(value), do: value |> to_string() |> String.replace("'", "''")

  def vector_opclass(%{distance: :l2}), do: "vector_l2_ops"
  def vector_opclass(%{distance: :inner_product}), do: "vector_ip_ops"
  def vector_opclass(_opts), do: "vector_cosine_ops"

  def normalize_distance(distance) when distance in [:cosine, "cosine"], do: :cosine
  def normalize_distance(distance) when distance in [:l2, :euclidean, "l2", "euclidean"], do: :l2

  def normalize_distance(distance)
      when distance in [:inner_product, :max_inner_product, "inner_product", "max_inner_product"],
      do: :inner_product

  def normalize_distance(_distance), do: :cosine

  def format_index_with(value, _opts) when is_binary(value), do: value

  def format_index_with(value, _opts) when is_list(value) and value != [] do
    Enum.map_join(value, ", ", fn {key, option_value} -> "#{key} = #{option_value}" end)
  end

  def format_index_with(_value, opts), do: Keyword.fetch!(opts, :default)
end
