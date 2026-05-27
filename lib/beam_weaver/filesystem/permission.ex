defmodule BeamWeaver.Filesystem.Permission do
  @moduledoc """
  Ordered allow/deny rule for DeepAgents filesystem tools.

  Rules are evaluated in list order. The first matching rule decides access;
  if no rule matches, access is allowed.
  """

  alias BeamWeaver.Filesystem.Utils

  defstruct operations: [:read, :write], paths: ["/**"], mode: :allow

  @type operation :: :read | :write | String.t()
  @type mode :: :allow | :deny | String.t()
  @type t :: %__MODULE__{operations: [operation()], paths: [String.t()], mode: mode()}

  def new(opts \\ []) do
    operations =
      opts
      |> Keyword.get(:operations, [:read, :write])
      |> List.wrap()
      |> Enum.map(&normalize_operation/1)

    paths =
      opts
      |> Keyword.get(:paths, ["/**"])
      |> List.wrap()
      |> Enum.map(&validate_path!/1)

    mode = opts |> Keyword.get(:mode, :allow) |> normalize_mode()

    %__MODULE__{
      operations: operations,
      paths: paths,
      mode: mode
    }
  end

  @spec allowed?([t() | map() | keyword()], operation(), String.t()) :: boolean()
  def allowed?(permissions, operation, path) do
    decision(permissions, operation, path) == :allow
  end

  @spec decision([t() | map() | keyword()], operation(), String.t()) :: :allow | :deny
  def decision(permissions, operation, path) do
    operation = normalize_operation(operation)
    path = normalize_match_path(path || "/")

    permissions
    |> List.wrap()
    |> Enum.map(&normalize/1)
    |> Enum.find(fn permission ->
      operation in permission.operations and Enum.any?(permission.paths, &path_match?(path, &1))
    end)
    |> case do
      nil -> :allow
      %__MODULE__{mode: :allow} -> :allow
      %__MODULE__{mode: :deny} -> :deny
    end
  end

  @spec filter_paths([t() | map() | keyword()], operation(), [String.t()]) :: [String.t()]
  def filter_paths(permissions, operation, paths) when is_list(paths) do
    Enum.filter(paths, &allowed?(permissions, operation, &1))
  end

  def normalize(%__MODULE__{} = permission), do: permission

  def normalize(permission) when is_map(permission) do
    new(
      operations: Map.get(permission, :operations, Map.get(permission, "operations", [:read, :write])),
      paths: Map.get(permission, :paths, Map.get(permission, "paths", ["/**"])),
      mode: Map.get(permission, :mode, Map.get(permission, "mode", :allow))
    )
  end

  def normalize(permission) when is_list(permission), do: new(permission)

  defp path_match?(path, pattern) do
    path = normalize_match_path(path)
    pattern = pattern |> to_string() |> normalize_match_path()

    if String.ends_with?(pattern, "/**") do
      prefix = String.trim_trailing(pattern, "/**")
      path == prefix or String.starts_with?(path, prefix <> "/")
    else
      pattern
      |> expand_braces()
      |> Enum.any?(fn pattern ->
        Utils.wildcard_match?(path, pattern) or
          Utils.wildcard_match?(String.trim_leading(path, "/"), pattern)
      end)
    end
  end

  defp normalize_operation(operation) when operation in [:read, "read"], do: :read
  defp normalize_operation(operation) when operation in [:write, "write"], do: :write

  defp normalize_operation(operation) do
    raise ArgumentError, "permission operation must be read or write, got: #{inspect(operation)}"
  end

  defp normalize_mode(mode) when mode in [:allow, "allow"], do: :allow
  defp normalize_mode(mode) when mode in [:deny, "deny"], do: :deny

  defp normalize_mode(mode) do
    raise ArgumentError, "permission mode must be allow or deny, got: #{inspect(mode)}"
  end

  defp validate_path!(path) when is_binary(path) do
    normalized = String.replace(path, "\\", "/")

    cond do
      not String.starts_with?(path, "/") ->
        raise ArgumentError, "permission path must start with '/'"

      String.contains?(normalized, "~") ->
        raise ArgumentError, "permission path must not contain '~'"

      ".." in Path.split(normalized) ->
        raise ArgumentError, "permission path must not contain '..'"

      true ->
        path
    end
  end

  defp validate_path!(path) do
    raise ArgumentError, "permission path must be a string, got: #{inspect(path)}"
  end

  defp normalize_match_path(path) do
    path
    |> to_string()
    |> String.replace("\\", "/")
    |> collapse_slashes()
  end

  defp collapse_slashes(path), do: Regex.replace(~r{/+}, path, "/")

  defp expand_braces(pattern) do
    case Regex.run(~r/\{([^{}]+)\}/, pattern, return: :index) do
      [{start, len}, {inner_start, inner_len}] ->
        prefix = binary_part(pattern, 0, start)
        suffix = binary_part(pattern, start + len, byte_size(pattern) - start - len)
        inner = binary_part(pattern, inner_start, inner_len)

        inner
        |> String.split(",")
        |> Enum.flat_map(&((prefix <> &1 <> suffix) |> expand_braces()))

      nil ->
        [pattern]
    end
  end
end
