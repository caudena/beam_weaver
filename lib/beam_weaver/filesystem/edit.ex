defmodule BeamWeaver.Filesystem.Edit do
  @moduledoc false

  @spec replacement(binary(), binary(), binary(), boolean()) ::
          {:ok, pos_integer(), binary()} | {:error, :not_found | :invalid_options | String.t()}
  def replacement(content, old, new, replace_all?)

  # An empty string is at every position of every file, so it names no edit.
  def replacement(content, "", new, replace_all?)
      when is_binary(content) and is_binary(new) and is_boolean(replace_all?),
      do: {:error, "old_string must not be empty"}

  def replacement(content, old, new, replace_all?)
      when is_binary(content) and is_binary(old) and is_binary(new) and is_boolean(replace_all?) do
    occurrences = length(:binary.matches(content, old))

    cond do
      occurrences == 0 -> {:error, :not_found}
      occurrences > 1 and not replace_all? -> {:error, "multiple occurrences"}
      true -> {:ok, occurrences, :binary.replace(content, old, new, if(replace_all?, do: [:global], else: []))}
    end
  end

  def replacement(_content, _old, _new, _replace_all?), do: {:error, :invalid_options}
end
