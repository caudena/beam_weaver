defmodule BeamWeaver.Diagnostics do
  @moduledoc """
  Runtime diagnostics and environment helpers.

  This is the Elixir-native counterpart to LangChain's runtime environment and
  sys-info helpers. It returns plain data for callers and only prints when
  explicitly asked.
  """

  alias BeamWeaver.Core.Error

  @doc """
  Returns BeamWeaver and VM runtime metadata.
  """
  @spec runtime_environment() :: map()
  def runtime_environment do
    %{
      "beam_weaver_version" => Application.spec(:beam_weaver, :vsn) |> to_string(),
      "elixir_version" => System.version(),
      "otp_release" => System.otp_release(),
      "erts_version" => :erlang.system_info(:version) |> to_string(),
      "system_architecture" => :erlang.system_info(:system_architecture) |> to_string(),
      "mix_env" => mix_env(),
      "schedulers" => System.schedulers_online()
    }
  end

  @doc """
  Prints runtime diagnostics in a deterministic order.
  """
  @spec print_sys_info(keyword()) :: :ok
  def print_sys_info(opts \\ []) do
    output = Keyword.get(opts, :output, &IO.puts/1)

    runtime_environment()
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.each(fn {key, value} -> output.("#{key}: #{value}") end)
  end

  @doc """
  Returns true when an environment variable exists and is not blank.
  """
  @spec env_var_set?(String.t()) :: boolean()
  def env_var_set?(name) when is_binary(name) do
    case System.get_env(name) do
      nil -> false
      value -> String.trim(value) != ""
    end
  end

  @doc """
  Fetches a value from a map or falls back to an environment variable.
  """
  @spec get_from_map_or_env(map(), atom() | String.t(), String.t(), keyword()) ::
          {:ok, String.t() | term()} | {:error, Error.t()}
  def get_from_map_or_env(map, key, env_name, opts \\ []) when is_map(map) do
    case fetch_map_key(map, key) do
      {:ok, value} when not is_nil(value) and value != "" ->
        {:ok, value}

      _missing ->
        get_from_env(env_name, opts)
    end
  end

  @doc """
  Fetches a non-blank environment variable or returns a default/error.
  """
  @spec get_from_env(String.t(), keyword()) :: {:ok, String.t() | term()} | {:error, Error.t()}
  def get_from_env(env_name, opts \\ []) when is_binary(env_name) do
    case System.get_env(env_name) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _missing ->
        if Keyword.has_key?(opts, :default) do
          {:ok, Keyword.fetch!(opts, :default)}
        else
          {:error,
           Error.new(:missing_environment_variable, "environment variable is not set", %{
             name: env_name
           })}
        end
    end
  end

  defp fetch_map_key(map, key) do
    cond do
      Map.has_key?(map, key) ->
        {:ok, Map.fetch!(map, key)}

      is_atom(key) and Map.has_key?(map, Atom.to_string(key)) ->
        {:ok, Map.fetch!(map, Atom.to_string(key))}

      is_binary(key) ->
        atom_key = existing_atom(key)

        if atom_key && Map.has_key?(map, atom_key) do
          {:ok, Map.fetch!(map, atom_key)}
        else
          :error
        end

      true ->
        :error
    end
  end

  defp existing_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp mix_env do
    if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) do
      Mix.env() |> Atom.to_string()
    end
  end
end
