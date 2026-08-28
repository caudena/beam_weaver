defmodule BeamWeaver.Filesystem.Edit do
  @moduledoc false

  @type replacement_error ::
          :empty_old_text
          | :not_found
          | :invalid_options
          | {:multiple_occurrences, pos_integer()}
          | {:occurrence_limit_exceeded, pos_integer()}

  @spec replacement(binary(), binary(), binary()) ::
          {:ok, pos_integer(), binary()} | {:error, replacement_error()}
  def replacement(content, old, new), do: replacement(content, old, new, [])

  @spec replacement(binary(), binary(), binary(), keyword() | boolean()) ::
          {:ok, pos_integer(), binary()}
          | {:error, replacement_error() | String.t()}
  def replacement(content, old, new, replace_all?) when is_boolean(replace_all?) do
    case replacement(content, old, new, replace_all: replace_all?) do
      {:error, :empty_old_text} -> {:error, :not_found}
      {:error, {:multiple_occurrences, _count}} -> {:error, "multiple occurrences"}
      result -> result
    end
  end

  def replacement(content, old, new, opts)
      when is_binary(content) and is_binary(old) and is_binary(new) and is_list(opts) do
    with {:ok, replace_all?, maximum_occurrences} <- validate_options(opts),
         :ok <- validate_old_text(old),
         {:ok, occurrences} <- count_occurrences(content, old, maximum_occurrences) do
      replace(content, old, new, replace_all?, occurrences)
    end
  end

  def replacement(_content, _old, _new, _opts), do: {:error, :invalid_options}

  @spec count_occurrences(binary(), binary()) :: non_neg_integer()
  def count_occurrences(_content, ""), do: 0

  def count_occurrences(content, needle) when is_binary(content) and is_binary(needle) do
    {:ok, count} = count_occurrences(content, needle, :infinity)
    count
  end

  defp replace(_content, _old, _new, _replace_all?, 0), do: {:error, :not_found}

  defp replace(_content, _old, _new, false, occurrences) when occurrences > 1,
    do: {:error, {:multiple_occurrences, occurrences}}

  defp replace(content, old, new, replace_all?, occurrences) do
    options = if replace_all?, do: [:global], else: []
    {:ok, occurrences, :binary.replace(content, old, new, options)}
  end

  defp validate_options(opts) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)
      replace_all? = Keyword.get(opts, :replace_all, false)
      maximum_occurrences = Keyword.get(opts, :max_occurrences, :infinity)

      if length(keys) == MapSet.size(MapSet.new(keys)) and
           Enum.all?(keys, &(&1 in [:replace_all, :max_occurrences])) and
           is_boolean(replace_all?) and
           (maximum_occurrences == :infinity or
              (is_integer(maximum_occurrences) and maximum_occurrences > 0)) do
        {:ok, replace_all?, maximum_occurrences}
      else
        {:error, :invalid_options}
      end
    else
      {:error, :invalid_options}
    end
  end

  defp validate_old_text(""), do: {:error, :empty_old_text}
  defp validate_old_text(_old), do: :ok

  defp count_occurrences(content, needle, maximum) do
    do_count_occurrences(content, needle, maximum, 0, 0)
  end

  defp do_count_occurrences(content, needle, maximum, offset, count) do
    remaining = byte_size(content) - offset

    case :binary.match(content, needle, scope: {offset, remaining}) do
      :nomatch ->
        {:ok, count}

      {_position, _length} when maximum != :infinity and count == maximum ->
        {:error, {:occurrence_limit_exceeded, maximum}}

      {position, length} ->
        do_count_occurrences(content, needle, maximum, position + length, count + 1)
    end
  end
end
