defmodule BeamWeaver.Config do
  @moduledoc """
  Runtime access to BeamWeaver application configuration.

  Runtime code should read BeamWeaver defaults through this module rather than
  reaching into application config directly.
  """

  @app :beam_weaver
  @missing :__beam_weaver_config_missing__

  @type path :: atom() | [atom() | String.t()]

  @doc """
  Returns a configured value from a grouped config path.

  Blank strings are treated as missing so env-derived config cannot silently
  override defaults with unusable values.
  """
  @spec get(path(), term()) :: term()
  def get(path, default \\ nil) do
    case do_get(path) do
      {:ok, value} -> value
      :error -> default
    end
  end

  @doc """
  Returns the raw configured group value.
  """
  @spec group(atom(), term()) :: term()
  def group(group, default \\ []) when is_atom(group), do: get(group, default)

  @doc """
  Returns a configured boolean flag from a grouped config path.

  Runtime code should prefer this helper over reading env vars directly. Env
  values belong in `config/runtime.exs` or test config and should arrive here
  as ordinary application config.
  """
  @spec flag?(path(), boolean()) :: boolean()
  def flag?(path, default \\ false) when is_boolean(default) do
    case get(path, default) do
      value when is_boolean(value) -> value
      value when is_binary(value) -> String.downcase(String.trim(value)) in ["1", "true", "yes", "on"]
      value when is_integer(value) -> value != 0
      _other -> default
    end
  end

  @doc """
  Resolves a keyword option with Application config fallback.

  Explicit options, including explicit `nil`, always win.
  """
  @spec option(keyword(), atom(), path(), term()) :: term()
  def option(opts, key, config_path, default \\ nil) when is_list(opts) and is_atom(key) do
    if Keyword.has_key?(opts, key) do
      Keyword.fetch!(opts, key)
    else
      get(config_path, default)
    end
  end

  defp application_env(key, default), do: Application.get_env(@app, key, default)

  defp do_get(group) when is_atom(group) do
    group
    |> application_env(@missing)
    |> present()
  end

  defp do_get([group | keys]) when is_atom(group) do
    group
    |> application_env([])
    |> fetch_path(keys)
  end

  defp fetch_path(value, []), do: present(value)

  defp fetch_path(value, [key | rest]) do
    with {:ok, next} <- fetch_key(value, key) do
      fetch_path(next, rest)
    end
  end

  defp fetch_key(data, key) when is_list(data) do
    cond do
      Keyword.keyword?(data) and Keyword.has_key?(data, key) ->
        present(Keyword.fetch!(data, key))

      is_binary(key) ->
        atom_key = existing_atom(key)

        if atom_key && Keyword.has_key?(data, atom_key) do
          present(Keyword.fetch!(data, atom_key))
        else
          :error
        end

      true ->
        :error
    end
  end

  defp fetch_key(data, key) when is_map(data) do
    cond do
      Map.has_key?(data, key) ->
        present(Map.fetch!(data, key))

      is_atom(key) and Map.has_key?(data, Atom.to_string(key)) ->
        present(Map.fetch!(data, Atom.to_string(key)))

      is_binary(key) ->
        atom_key = existing_atom(key)

        if atom_key && Map.has_key?(data, atom_key) do
          present(Map.fetch!(data, atom_key))
        else
          :error
        end

      true ->
        :error
    end
  end

  defp fetch_key(_data, _key), do: :error

  defp present(@missing), do: :error
  defp present(value) when value in [nil, ""], do: :error

  defp present(value) when is_binary(value) do
    if String.trim(value) == "", do: :error, else: {:ok, value}
  end

  defp present(value), do: {:ok, value}

  defp existing_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end
end
