defmodule BeamWeaver.Policy do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.MapAccess

  @type validate_fun :: (struct() -> {:ok, struct()} | {:error, Error.t()})

  @spec build(module(), keyword() | map() | struct(), [atom()], validate_fun(), keyword()) ::
          {:ok, struct()} | {:error, Error.t()}
  def build(module, opts, fields, validate, build_opts \\ [])

  def build(module, %{__struct__: module} = policy, _fields, validate, _build_opts),
    do: validate.(policy)

  def build(module, opts, fields, validate, build_opts) when is_list(opts),
    do: build(module, Map.new(opts), fields, validate, build_opts)

  def build(module, opts, fields, validate, build_opts) when is_map(opts) do
    with {:ok, attrs} <- normalize_keys(opts, fields, build_opts) do
      module
      |> struct(attrs)
      |> validate.()
    end
  end

  @spec bang({:ok, struct()} | {:error, Error.t()}) :: struct() | no_return()
  def bang({:ok, policy}), do: policy
  def bang({:error, %Error{} = error}), do: raise(ArgumentError, error.message)

  @spec valid_timeout?(term()) :: boolean()
  def valid_timeout?(nil), do: true
  def valid_timeout?(:infinity), do: true
  def valid_timeout?(timeout), do: is_integer(timeout) and timeout >= 0

  @spec duration_to_ms(term()) :: term()
  def duration_to_ms(value) when is_float(value), do: round(value * 1_000)
  def duration_to_ms(value), do: value

  defp normalize_keys(map, fields, opts) do
    normalize = Keyword.get(opts, :normalize, fn _key, value -> value end)
    attrs = MapAccess.normalize_keys(map, fields)
    unknown = if Keyword.get(opts, :unknown) == :error, do: Enum.reject(Map.keys(attrs), &(&1 in fields)), else: []

    case unknown do
      [] ->
        {:ok, Map.new(attrs, fn {key, value} -> {key, if(key in fields, do: normalize.(key, value), else: value)} end)}

      [key | _rest] ->
        message = Keyword.get(opts, :unknown_message, "unknown policy option")
        {:error, Error.new(Keyword.fetch!(opts, :error_type), message, %{option: inspect(key)})}
    end
  end
end
