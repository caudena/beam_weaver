defmodule BeamWeaver.TextSplitter.RecursiveJSON do
  @moduledoc false
  alias BeamWeaver.Core.Document
  alias BeamWeaver.TextSplitter.{Documents, Shared}

  defstruct Shared.common_fields() ++ [min_chunk_size: nil]

  @separators ["\n", ",", "{", "}", "[", "]", " ", ""]
  def new(opts), do: struct(__MODULE__, Shared.normalize_opts(opts, separators: @separators))
  def split_text(%__MODULE__{} = splitter, text), do: Shared.split_text(splitter, text)
  def split_document(splitter, document), do: Shared.split_document(splitter, document)

  def split_json(%__MODULE__{} = splitter, json_data, opts) do
    json_data = if Keyword.get(opts, :convert_lists) == true, do: convert_lists(json_data), else: json_data
    split_json_value(json_data, splitter)
  end

  def split_json_text(%__MODULE__{} = splitter, json_data, opts) do
    splitter
    |> split_json(json_data, opts)
    |> Enum.map(&BeamWeaver.JSON.encode!/1)
  end

  def create_json_documents(%__MODULE__{} = splitter, values, opts) when is_list(values) do
    metadata = Keyword.get(opts, :metadata, %{})

    values
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} ->
      splitter
      |> split_json_text(value, opts)
      |> Enum.map(&Document.new!(&1, metadata: Documents.metadata_for_index(metadata, index)))
    end)
  end

  defp split_json_value(map, splitter) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.flat_map(&entry_chunks(&1, splitter))
    |> repack_entries(splitter, [], %{})
    |> merge_small_chunks(splitter)
  end

  defp split_json_value(value, _splitter), do: [value]

  defp entry_chunks({key, value}, splitter) when is_list(value) or (is_map(value) and map_size(value) > 0) do
    entry = %{key => value}

    if encoded_size(entry) <= chunk_limit(splitter) do
      [entry]
    else
      value
      |> index_keys()
      |> split_json_value(nested_splitter(splitter, key))
      |> Enum.map(&%{key => &1})
    end
  end

  defp entry_chunks({key, value}, _splitter), do: [%{key => value}]

  defp repack_entries([], _splitter, chunks, current) when current == %{},
    do: Enum.reverse(chunks)

  defp repack_entries([], _splitter, chunks, current),
    do: Enum.reverse([current | chunks])

  defp repack_entries([entry | rest], splitter, chunks, current) when current == %{} do
    repack_entries(rest, splitter, chunks, entry)
  end

  defp repack_entries([entry | rest], splitter, chunks, current) do
    merged = deep_merge(current, entry)

    if encoded_size(merged) <= chunk_limit(splitter) do
      repack_entries(rest, splitter, chunks, merged)
    else
      repack_entries(rest, splitter, [current | chunks], entry)
    end
  end

  defp convert_lists(values) when is_list(values), do: values |> index_keys() |> convert_lists()
  defp convert_lists(map) when is_map(map), do: Map.new(map, fn {key, value} -> {key, convert_lists(value)} end)
  defp convert_lists(value), do: value

  defp index_keys(values) when is_list(values),
    do: values |> Enum.with_index() |> Map.new(fn {item, index} -> {Integer.to_string(index), item} end)

  defp index_keys(map), do: map

  defp deep_merge(left, right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        deep_merge(left_value, right_value)
      else
        right_value
      end
    end)
  end

  defp encoded_size(value), do: value |> BeamWeaver.JSON.encode!() |> byte_size()
  defp chunk_limit(splitter), do: trunc(splitter.chunk_size * 1.05)
  defp min_chunk_size(%{min_chunk_size: size}) when is_integer(size) and size > 0, do: size
  defp min_chunk_size(_splitter), do: 0

  defp merge_small_chunks(chunks, splitter) do
    min_size = min_chunk_size(splitter)

    if min_size == 0 do
      chunks
    else
      chunks
      |> Enum.reduce([], fn chunk, acc ->
        case acc do
          [previous | rest] ->
            merged = deep_merge(previous, chunk)

            if encoded_size(previous) < min_size and encoded_size(merged) <= chunk_limit(splitter) do
              [merged | rest]
            else
              [chunk | acc]
            end

          [] ->
            [chunk]
        end
      end)
      |> Enum.reverse()
    end
  end

  defp nested_splitter(splitter, key) do
    overhead = encoded_size(%{key => %{}})
    %{splitter | chunk_size: max(splitter.chunk_size - overhead, 1)}
  end
end
