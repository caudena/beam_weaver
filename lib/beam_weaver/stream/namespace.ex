defmodule BeamWeaver.Stream.Namespace do
  @moduledoc false

  @spec normalize(term(), keyword()) :: [term()]
  def normalize(namespace, opts \\ []) do
    namespace = List.wrap(namespace)
    if Keyword.get(opts, :stringify, false), do: Enum.map(namespace, &to_string/1), else: namespace
  end
end
