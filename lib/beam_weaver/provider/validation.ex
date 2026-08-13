defmodule BeamWeaver.Provider.Validation do
  @moduledoc false

  alias BeamWeaver.Core.Error

  @default_max_bytes 16 * 1024 * 1024
  @default_max_items 100_000
  @default_max_depth 64

  def measure(value, opts \\ []) do
    limits = %{
      bytes: Keyword.get(opts, :max_bytes, @default_max_bytes),
      items: Keyword.get(opts, :max_items, @default_max_items),
      depth: Keyword.get(opts, :max_depth, @default_max_depth)
    }

    bytes = :erlang.external_size(value)

    with :ok <- valid_limits(limits),
         true <- bytes <= limits.bytes,
         {:ok, items, depth} <- walk([{value, 0}], 0, 0, limits) do
      {:ok, %{bytes: bytes, items: items, depth: depth}}
    else
      false -> invalid("provider value exceeds its byte limit", limits)
      {:error, _reason} = error -> error
    end
  end

  defp walk([], items, depth, _limits), do: {:ok, items, depth}

  defp walk(_pending, items, _depth, %{items: maximum}) when items > maximum,
    do: invalid("provider value has too many items", %{maximum: maximum})

  defp walk([{_value, depth} | _pending], _items, _maximum_depth, %{depth: maximum})
       when depth > maximum,
       do: invalid("provider value is too deeply nested", %{maximum: maximum})

  defp walk([{value, depth} | pending], items, maximum_depth, limits) do
    children = children(value, depth)
    walk(children ++ pending, items + 1, max(depth, maximum_depth), limits)
  end

  defp children(value, _depth)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value) or
              is_atom(value),
       do: []

  defp children(values, depth) when is_list(values),
    do: Enum.map(values, &{&1, depth + 1})

  defp children(value, depth) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&{&1, depth + 1})

  defp children(%{__struct__: _module} = value, depth),
    do: children(Map.from_struct(value), depth)

  defp children(value, depth) when is_map(value) do
    Enum.flat_map(value, fn {key, item} -> [{key, depth + 1}, {item, depth + 1}] end)
  end

  defp children(_value, _depth), do: []

  defp valid_limits(%{bytes: bytes, items: items, depth: depth})
       when is_integer(bytes) and bytes > 0 and is_integer(items) and items > 0 and
              is_integer(depth) and depth > 0,
       do: :ok

  defp valid_limits(_limits), do: invalid("provider validation limits are invalid")

  defp invalid(message, details \\ %{}),
    do: {:error, Error.new(:invalid_provider_response, message, details)}
end
