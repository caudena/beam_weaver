defmodule BeamWeaver.Memory.Query do
  @moduledoc false

  alias BeamWeaver.Memory.SearchItem

  @reserved_root "beam_weaver"

  def normalize_namespace(namespace) when is_list(namespace),
    do: Enum.map(namespace, &to_string/1)

  def normalize_namespace(namespace), do: [to_string(namespace)]

  def validate_namespace(namespace) do
    cond do
      namespace == [] ->
        {:error, {:invalid_namespace, "namespace cannot be empty"}}

      Enum.any?(namespace, &(&1 == "")) ->
        {:error, {:invalid_namespace, "namespace parts cannot be empty"}}

      Enum.any?(namespace, &String.contains?(&1, ".")) ->
        {:error, {:invalid_namespace, "namespace parts cannot contain dots"}}

      List.first(namespace) == @reserved_root ->
        {:error, {:invalid_namespace, "namespace cannot start with beam_weaver"}}

      true ->
        :ok
    end
  end

  def search_items(items, namespace_prefix, opts) do
    query = Keyword.get(opts, :query)
    filter = Keyword.get(opts, :filter, %{})
    limit = Keyword.get(opts, :limit, 10)
    offset = Keyword.get(opts, :offset, 0)

    items
    |> Enum.filter(
      &(namespace_prefix?(&1.namespace, namespace_prefix) and matches_query?(&1, query) and matches_filter?(&1, filter))
    )
    |> Enum.sort_by(&DateTime.to_unix(&1.updated_at, :microsecond), :desc)
    |> Enum.drop(offset)
    |> Enum.take(limit)
  end

  def vector_search_items(items, namespace_prefix, scored_items, opts) do
    filter = Keyword.get(opts, :filter, %{})
    limit = Keyword.get(opts, :limit, 10)
    offset = Keyword.get(opts, :offset, 0)
    scored = Map.new(scored_items)

    items
    |> Enum.filter(&(namespace_prefix?(&1.namespace, namespace_prefix) and matches_filter?(&1, filter)))
    |> Enum.map(fn item ->
      SearchItem.from_item(item, Map.get(scored, {item.namespace, item.key}))
    end)
    |> Enum.sort_by(fn item ->
      score_rank =
        case item.score do
          nil -> {1, 0.0}
          score -> {0, -score}
        end

      {score_rank, -DateTime.to_unix(item.updated_at, :microsecond), item.key}
    end)
    |> Enum.drop(offset)
    |> Enum.take(limit)
  end

  def list_namespaces(namespaces, opts) do
    prefix = Keyword.get(opts, :prefix, [])
    suffix = Keyword.get(opts, :suffix, [])
    max_depth = Keyword.get(opts, :max_depth)
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)

    namespaces
    |> Enum.filter(&(namespace_path_match?(&1, prefix, :prefix) and namespace_path_match?(&1, suffix, :suffix)))
    |> Enum.map(&truncate_namespace(&1, max_depth))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.drop(offset)
    |> Enum.take(limit)
  end

  def namespace_prefix?(_namespace, []), do: true

  def namespace_prefix?(namespace, prefix) do
    length(namespace) >= length(prefix) and Enum.take(namespace, length(prefix)) == prefix
  end

  def namespace_path_match?(_namespace, [], _type), do: true

  def namespace_path_match?(namespace, path, :prefix) do
    length(namespace) >= length(path) and
      namespace
      |> Enum.take(length(path))
      |> wildcard_match?(path)
  end

  def namespace_path_match?(namespace, path, :suffix) do
    length(namespace) >= length(path) and
      namespace
      |> Enum.take(-length(path))
      |> wildcard_match?(path)
  end

  def matches_filter?(_item, filter) when filter in [nil, %{}], do: true

  def matches_filter?(item, filter) do
    Enum.all?(filter, fn {key, expected} ->
      value =
        item.value
        |> value_at(key)
        |> case do
          :missing -> value_at(item.metadata || %{}, key)
          value -> value
        end

      compare(value, expected)
    end)
  end

  def matches_query?(_item, nil), do: true

  def matches_query?(item, query) do
    haystack =
      %{value: item.value, metadata: item.metadata}
      |> inspect()
      |> String.downcase()

    String.contains?(haystack, String.downcase(to_string(query)))
  end

  def get_text_at_path(nil, _path), do: []

  def get_text_at_path(value, path) when path in ["", "$"] do
    [json_text(value)]
  end

  def get_text_at_path(value, path) do
    case normalize_path(path) do
      {:ok, tokens} ->
        value
        |> extract_tokens(tokens)
        |> Enum.flat_map(&string_values/1)

      :error ->
        []
    end
  end

  def expired?(%{expires_at: nil}), do: false

  def expired?(%{expires_at: expires_at}),
    do: DateTime.compare(DateTime.utc_now(), expires_at) != :lt

  def expired?(_item), do: false

  def refresh_expiry(item, nil), do: item
  def refresh_expiry(item, ttl_minutes), do: Map.put(item, :expires_at, expires_at(ttl_minutes))

  def expires_at(nil), do: nil
  def expires_at(:not_provided), do: nil

  def expires_at(ttl_minutes) when is_number(ttl_minutes) do
    milliseconds = max(round(ttl_minutes * 60_000), 1)
    DateTime.add(DateTime.utc_now(), milliseconds, :millisecond)
  end

  defp wildcard_match?(values, pattern) do
    Enum.zip(values, pattern)
    |> Enum.all?(fn
      {_value, "*"} -> true
      {value, value} -> true
      _other -> false
    end)
  end

  defp truncate_namespace(namespace, nil), do: namespace
  defp truncate_namespace(namespace, max_depth), do: Enum.take(namespace, max_depth)

  defp value_at(map, key) when is_map(map) do
    key = to_string(key)

    cond do
      String.contains?(key, ".") ->
        nested_value_at(map, String.split(key, "."))

      Map.has_key?(map, key) ->
        Map.fetch!(map, key)

      Enum.any?(Map.keys(map), &(to_string(&1) == key)) ->
        map[Enum.find(Map.keys(map), &(to_string(&1) == key))]

      true ->
        :missing
    end
  end

  defp nested_value_at(value, []), do: value

  defp nested_value_at(map, [key | rest]) when is_map(map) do
    cond do
      Map.has_key?(map, key) ->
        nested_value_at(Map.fetch!(map, key), rest)

      Enum.any?(Map.keys(map), &(to_string(&1) == key)) ->
        nested_value_at(map[Enum.find(Map.keys(map), &(to_string(&1) == key))], rest)

      true ->
        :missing
    end
  end

  defp nested_value_at(_value, _path), do: :missing

  defp compare(:missing, _expected), do: false

  defp compare(value, expected) when is_map(expected) do
    Enum.all?(expected, fn {op, op_value} -> apply_operator(value, to_string(op), op_value) end)
  end

  defp compare(value, expected), do: value == expected

  defp apply_operator(value, "$eq", expected), do: value == expected
  defp apply_operator(value, "$ne", expected), do: value != expected
  defp apply_operator(value, "$gt", expected), do: value > expected
  defp apply_operator(value, "$gte", expected), do: value >= expected
  defp apply_operator(value, "$lt", expected), do: value < expected
  defp apply_operator(value, "$lte", expected), do: value <= expected
  defp apply_operator(value, "$in", expected) when is_list(expected), do: value in expected
  defp apply_operator(value, "$nin", expected) when is_list(expected), do: value not in expected
  defp apply_operator(_value, _op, _expected), do: false

  def tokenize_path(path) when is_binary(path) do
    with {:ok, tokens} <- do_tokenize(String.graphemes(path), [], "") do
      {:ok, Enum.reverse(tokens)}
    end
  end

  def tokenize_path(tokens) when is_list(tokens) do
    normalize_token_list(tokens)
  end

  defp do_tokenize([], tokens, current), do: {:ok, finalize_token(tokens, current)}

  defp do_tokenize(["." | rest], tokens, current),
    do: do_tokenize(rest, finalize_token(tokens, current), "")

  defp do_tokenize(["[" | rest], tokens, current) do
    with {inside, rest} when inside != nil <- take_until(rest, "]"),
         {:ok, token} <- inside |> Enum.join() |> bracket_token() do
      do_tokenize(rest, [token | finalize_token(tokens, current)], "")
    else
      _error -> :error
    end
  end

  defp do_tokenize(["{" | rest], tokens, current) do
    with {inside, rest} when inside != nil <- take_until(rest, "}"),
         options when options != [] <-
           inside |> Enum.join() |> String.split(",", trim: true) |> Enum.map(&String.trim/1),
         true <- Enum.all?(options, &(&1 != "")) do
      do_tokenize(rest, [{:union, options} | finalize_token(tokens, current)], "")
    else
      _error -> :error
    end
  end

  defp do_tokenize([char | rest], tokens, current),
    do: do_tokenize(rest, tokens, current <> char)

  defp finalize_token(tokens, ""), do: tokens
  defp finalize_token(tokens, "*"), do: [:wildcard | tokens]
  defp finalize_token(tokens, current), do: [{:key, current} | tokens]

  defp take_until(chars, terminator), do: do_take_until(chars, terminator, [])

  defp do_take_until([], _terminator, _acc), do: {nil, []}
  defp do_take_until([terminator | rest], terminator, acc), do: {Enum.reverse(acc), rest}

  defp do_take_until([char | rest], terminator, acc),
    do: do_take_until(rest, terminator, [char | acc])

  defp bracket_token("*"), do: {:ok, :wildcard}

  defp bracket_token(value) do
    case Integer.parse(value) do
      {index, ""} -> {:ok, {:index, index}}
      _other -> :error
    end
  end

  defp normalize_path(path) when path in ["", "$"], do: {:ok, []}
  defp normalize_path(path) when is_binary(path), do: tokenize_path(path)
  defp normalize_path(tokens) when is_list(tokens), do: tokenize_path(tokens)
  defp normalize_path(_path), do: :error

  defp normalize_token_list(tokens) do
    Enum.reduce_while(tokens, {:ok, []}, fn token, {:ok, acc} ->
      case normalize_token(token) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      :error -> :error
    end
  end

  defp normalize_token({:key, key}) when is_binary(key), do: {:ok, {:key, key}}
  defp normalize_token({:index, index}) when is_integer(index), do: {:ok, {:index, index}}
  defp normalize_token({:union, options}) when is_list(options), do: {:ok, {:union, options}}
  defp normalize_token(:wildcard), do: {:ok, :wildcard}
  defp normalize_token("*"), do: {:ok, :wildcard}

  defp normalize_token("[" <> rest = token) do
    if String.ends_with?(token, "]") do
      rest
      |> String.trim_trailing("]")
      |> bracket_token()
    else
      :error
    end
  end

  defp normalize_token("{" <> rest = token) do
    if String.ends_with?(token, "}") do
      options =
        rest
        |> String.trim_trailing("}")
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)

      if Enum.all?(options, &(&1 != "")), do: {:ok, {:union, options}}, else: :error
    else
      :error
    end
  end

  defp normalize_token(token) when is_binary(token), do: {:ok, {:key, token}}
  defp normalize_token(_token), do: :error

  defp extract_tokens(value, tokens), do: do_extract_tokens([value], tokens)

  defp do_extract_tokens(values, []), do: values

  defp do_extract_tokens(values, [{:key, key} | rest]) do
    values
    |> Enum.flat_map(&extract_key(&1, key))
    |> do_extract_tokens(rest)
  end

  defp do_extract_tokens(values, [{:index, index} | rest]) do
    values
    |> Enum.flat_map(&extract_index(&1, index))
    |> do_extract_tokens(rest)
  end

  defp do_extract_tokens(values, [:wildcard | rest]) do
    values
    |> Enum.flat_map(&extract_wildcard/1)
    |> do_extract_tokens(rest)
  end

  defp do_extract_tokens(values, [{:union, options} | rest]) do
    values
    |> Enum.flat_map(fn value ->
      Enum.flat_map(options, fn option ->
        case tokenize_path(option) do
          {:ok, tokens} -> extract_tokens(value, tokens)
          :error -> []
        end
      end)
    end)
    |> do_extract_tokens(rest)
  end

  defp extract_key(map, key) when is_map(map) do
    cond do
      Map.has_key?(map, key) ->
        [Map.fetch!(map, key)]

      Enum.any?(Map.keys(map), &(to_string(&1) == key)) ->
        [map[Enum.find(Map.keys(map), &(to_string(&1) == key))]]

      true ->
        []
    end
  end

  defp extract_key(_value, _key), do: []

  defp extract_index(list, index) when is_list(list) do
    index = if index < 0, do: length(list) + index, else: index

    case Enum.fetch(list, index) do
      {:ok, value} -> [value]
      :error -> []
    end
  end

  defp extract_index(_value, _index), do: []

  defp extract_wildcard(map) when is_map(map), do: Map.values(map)
  defp extract_wildcard(list) when is_list(list), do: list
  defp extract_wildcard(_value), do: []

  defp string_values(nil), do: []
  defp string_values(value) when is_binary(value), do: [value]
  defp string_values(value) when is_integer(value), do: [Integer.to_string(value)]
  defp string_values(value) when is_float(value), do: [Float.to_string(value)]
  defp string_values(value) when is_boolean(value), do: [to_string(value)]
  defp string_values(value) when is_map(value) and map_size(value) == 0, do: [json_text(value)]
  defp string_values(value) when is_list(value) and value == [], do: [json_text(value)]
  defp string_values(value) when is_map(value) or is_list(value), do: [json_text(value)]
  defp string_values(value), do: [to_string(value)]

  defp json_text(value), do: value |> sort_json_value() |> BeamWeaver.JSON.encode!()

  defp sort_json_value(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, value} -> {to_string(key), sort_json_value(value)} end)
    |> Map.new()
  end

  defp sort_json_value(list) when is_list(list), do: Enum.map(list, &sort_json_value/1)
  defp sort_json_value(value), do: value
end
