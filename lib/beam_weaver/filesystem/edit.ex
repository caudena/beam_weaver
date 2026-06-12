defmodule BeamWeaver.Filesystem.Edit do
  @moduledoc false

  alias BeamWeaver.Filesystem.Utils

  def replacement(content, old, new, replace_all?) when is_binary(content) do
    occurrences = Utils.count_occurrences(content, old)

    cond do
      occurrences == 0 ->
        {:error, :not_found}

      replace_all? ->
        {:ok, occurrences, String.replace(content, old, new)}

      occurrences == 1 ->
        {:ok, occurrences, String.replace(content, old, new, global: false)}

      true ->
        {:error, "multiple occurrences"}
    end
  end
end
