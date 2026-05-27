defmodule BeamWeaver.Policy do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.MapAccess

  @type normalize_fun :: (atom(), term() -> term())
  @type validate_fun :: (struct() -> {:ok, struct()} | {:error, Error.t()})

  @spec build(
          module(),
          keyword() | map() | struct(),
          [atom()] | MapSet.t(atom()),
          validate_fun(),
          keyword()
        ) ::
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
    fields = fields_list(fields)

    case Keyword.get(opts, :unknown, :ignore) do
      :error -> normalize_strict_keys(map, fields, opts)
      :ignore -> {:ok, normalize_known_keys(map, fields, opts)}
    end
  end

  defp normalize_known_keys(map, fields, opts) do
    normalize = Keyword.get(opts, :normalize, &default_normalize/2)

    map
    |> MapAccess.normalize_keys(fields)
    |> Map.new(fn {key, value} ->
      value = if key in fields, do: normalize.(key, value), else: value
      {key, value}
    end)
  end

  defp normalize_strict_keys(map, fields, opts) do
    field_set = MapSet.new(fields)

    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case normalize_strict_option(key, value, field_set, opts) do
        {:ok, normalized_key, normalized_value} ->
          {:cont, {:ok, Map.put(acc, normalized_key, normalized_value)}}

        {:error, %Error{} = error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp normalize_strict_option(key, value, field_set, opts) do
    normalize = Keyword.get(opts, :normalize, &default_normalize/2)

    case strict_key(key, field_set) do
      {:ok, normalized_key} ->
        {:ok, normalized_key, normalize.(normalized_key, value)}

      :error ->
        invalid(
          Keyword.fetch!(opts, :error_type),
          Keyword.get(opts, :unknown_message, "unknown policy option"),
          %{option: inspect(key)}
        )
    end
  end

  defp strict_key(key, field_set) when is_atom(key) do
    if MapSet.member?(field_set, key), do: {:ok, key}, else: :error
  end

  defp strict_key(key, field_set) when is_binary(key) do
    Enum.find_value(field_set, :error, fn field ->
      if Atom.to_string(field) == key, do: {:ok, field}
    end)
  end

  defp strict_key(_key, _field_set), do: :error

  defp fields_list(%MapSet{} = fields), do: MapSet.to_list(fields)
  defp fields_list(fields), do: fields

  defp default_normalize(_key, value), do: value

  @spec invalid(atom(), String.t(), map()) :: {:error, Error.t()}
  def invalid(type, message, details \\ %{}),
    do: {:error, Error.new(type, message, details)}
end
