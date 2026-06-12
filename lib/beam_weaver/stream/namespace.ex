defmodule BeamWeaver.Stream.Namespace do
  @moduledoc false

  @spec normalize(term(), keyword()) :: [term()]
  def normalize(namespace, opts \\ [])

  def normalize(nil, _opts), do: []

  def normalize(namespace, opts) when is_list(namespace) do
    if Keyword.get(opts, :stringify, false) do
      Enum.map(namespace, &to_string/1)
    else
      namespace
    end
  end

  def normalize(namespace, opts) do
    if Keyword.get(opts, :stringify, false), do: [to_string(namespace)], else: [namespace]
  end
end
