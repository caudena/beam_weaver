defmodule BeamWeaver.ShellPolicy do
  @moduledoc """
  Explicit policy for shell-tool execution.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.MapAccess

  defstruct allow: [],
            deny: [],
            cwd: nil,
            env: %{},
            env_allowlist: [],
            timeout: 5_000,
            max_output_bytes: 20_000,
            stderr: :merge,
            empty_output: nil,
            truncation_indicator: nil,
            redactions: [],
            executor: nil

  @fields [
    :allow,
    :deny,
    :cwd,
    :env,
    :env_allowlist,
    :timeout,
    :max_output_bytes,
    :stderr,
    :empty_output,
    :truncation_indicator,
    :redactions,
    :executor
  ]

  @type stderr_policy :: :merge | :separate | :discard

  @type t :: %__MODULE__{
          allow: [String.t() | Regex.t()],
          deny: [String.t() | Regex.t()],
          cwd: Path.t() | nil,
          env: map(),
          env_allowlist: [String.t()],
          timeout: timeout(),
          max_output_bytes: pos_integer(),
          stderr: stderr_policy(),
          empty_output: String.t() | nil,
          truncation_indicator: String.t() | true | nil,
          redactions: [{Regex.t(), String.t()}],
          executor: module() | struct()
        }

  def new(opts \\ [])
  def new(%__MODULE__{} = policy), do: validate(policy)
  def new(opts) when is_list(opts), do: opts |> Map.new() |> new()

  def new(opts) when is_map(opts) do
    %__MODULE__{}
    |> struct(normalize_keys(opts))
    |> validate()
  end

  def new!(opts \\ []) do
    case new(opts) do
      {:ok, policy} -> policy
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  def validate(%__MODULE__{} = policy) do
    cond do
      policy.allow == [] ->
        invalid("shell policy requires at least one allow rule")

      not Enum.all?(policy.allow, &rule?/1) ->
        invalid("allow rules must be strings or regexes")

      not Enum.all?(policy.deny, &rule?/1) ->
        invalid("deny rules must be strings or regexes")

      not valid_timeout?(policy.timeout) ->
        invalid("timeout must be nil, :infinity, or a non-negative integer")

      not is_integer(policy.max_output_bytes) or policy.max_output_bytes < 1 ->
        invalid("max_output_bytes must be a positive integer")

      policy.stderr not in [:merge, :separate, :discard] ->
        invalid("stderr must be :merge, :separate, or :discard")

      not valid_empty_output?(policy.empty_output) ->
        invalid("empty_output must be nil or a string")

      not valid_truncation_indicator?(policy.truncation_indicator) ->
        invalid("truncation_indicator must be nil, true, or a string")

      not valid_redactions?(policy.redactions) ->
        invalid("redactions must be {regex, replacement} pairs")

      true ->
        {:ok,
         %{
           policy
           | executor: policy.executor || default_executor(),
             redactions: normalize_redactions(policy.redactions)
         }}
    end
  end

  def allowed?(%__MODULE__{} = policy, command) when is_binary(command) do
    allowed = Enum.any?(policy.allow, &allow_rule_match?(&1, command))
    denied = Enum.any?(policy.deny, &deny_rule_match?(&1, command))
    allowed and not denied
  end

  defp rule?(rule), do: is_binary(rule) or match?(%Regex{}, rule)
  defp allow_rule_match?(%Regex{} = regex, command), do: Regex.match?(regex, command)

  defp allow_rule_match?(prefix, command) when is_binary(prefix),
    do: String.starts_with?(command, prefix) and prefix_boundary?(prefix, command) and shell_single_command?(command)

  defp deny_rule_match?(%Regex{} = regex, command), do: Regex.match?(regex, command)

  defp deny_rule_match?(prefix, command) when is_binary(prefix),
    do: String.starts_with?(command, prefix) and prefix_boundary?(prefix, command)

  defp prefix_boundary?(prefix, command) do
    prefix_size = byte_size(prefix)

    cond do
      byte_size(command) == prefix_size ->
        true

      String.match?(prefix, ~r/\s$/u) ->
        true

      true ->
        command
        |> binary_part(prefix_size, byte_size(command) - prefix_size)
        |> String.first()
        |> whitespace?()
    end
  end

  defp shell_single_command?(command), do: shell_single_command?(command, :normal, false)

  defp shell_single_command?("", _state, _escaped), do: true

  defp shell_single_command?(<<_char::utf8, rest::binary>>, state, true),
    do: shell_single_command?(rest, state, false)

  defp shell_single_command?(<<"\\", rest::binary>>, :single_quote, false),
    do: shell_single_command?(rest, :single_quote, false)

  defp shell_single_command?(<<"\\", rest::binary>>, state, false),
    do: shell_single_command?(rest, state, true)

  defp shell_single_command?(<<"'", rest::binary>>, :normal, false),
    do: shell_single_command?(rest, :single_quote, false)

  defp shell_single_command?(<<"'", rest::binary>>, :single_quote, false),
    do: shell_single_command?(rest, :normal, false)

  defp shell_single_command?(<<"\"", rest::binary>>, :normal, false),
    do: shell_single_command?(rest, :double_quote, false)

  defp shell_single_command?(<<"\"", rest::binary>>, :double_quote, false),
    do: shell_single_command?(rest, :normal, false)

  defp shell_single_command?(<<"`", _rest::binary>>, state, false) when state != :single_quote,
    do: false

  defp shell_single_command?(<<"$(", _rest::binary>>, state, false) when state != :single_quote,
    do: false

  defp shell_single_command?(<<char::utf8, _rest::binary>>, :normal, false) when char in [?;, ?|, ?\n, ?\r],
    do: false

  defp shell_single_command?(<<">&", rest::binary>>, :normal, false),
    do: shell_single_command?(rest, :normal, false)

  defp shell_single_command?(<<"<&", rest::binary>>, :normal, false),
    do: shell_single_command?(rest, :normal, false)

  defp shell_single_command?(<<"&&", _rest::binary>>, :normal, false), do: false
  defp shell_single_command?(<<"&", _rest::binary>>, :normal, false), do: false

  defp shell_single_command?(<<_char::utf8, rest::binary>>, state, false),
    do: shell_single_command?(rest, state, false)

  defp whitespace?(value) when value in [" ", "\t", "\n", "\r"], do: true
  defp whitespace?(_value), do: false

  defp valid_timeout?(nil), do: true
  defp valid_timeout?(:infinity), do: true
  defp valid_timeout?(timeout), do: is_integer(timeout) and timeout >= 0

  defp valid_empty_output?(nil), do: true
  defp valid_empty_output?(value), do: is_binary(value)

  defp valid_truncation_indicator?(value) when value in [nil, true], do: true
  defp valid_truncation_indicator?(value), do: is_binary(value)

  defp valid_redactions?(redactions) when is_list(redactions) do
    Enum.all?(redactions, fn
      {%Regex{}, replacement} when is_binary(replacement) -> true
      %{pattern: %Regex{}, replacement: replacement} when is_binary(replacement) -> true
      %{"pattern" => %Regex{}, "replacement" => replacement} when is_binary(replacement) -> true
      _other -> false
    end)
  end

  defp valid_redactions?(_redactions), do: false

  defp normalize_redactions(redactions) do
    Enum.map(redactions, fn
      {%Regex{} = regex, replacement} -> {regex, replacement}
      %{pattern: %Regex{} = regex, replacement: replacement} -> {regex, replacement}
      %{"pattern" => %Regex{} = regex, "replacement" => replacement} -> {regex, replacement}
    end)
  end

  defp normalize_keys(map) do
    MapAccess.normalize_keys(map, @fields)
  end

  defp default_executor do
    Module.concat([BeamWeaver, Tools, Shell, HostExecutor])
  end

  defp invalid(message), do: {:error, Error.new(:invalid_shell_policy, message)}
end
