defmodule BeamWeaver.ShellPolicy do
  @moduledoc """
  Explicit policy for shell-tool execution.

  A command runs only when an `:allow` rule allows it and no `:deny` rule
  matches it. A string rule allows a command that starts with it, followed by
  nothing or by arguments; a regex rule allows a command it matches. Both
  allow a single command only: a line that chains commands with `;`, `&&`,
  `||`, `|`, `&` or a newline, or runs one in a subshell `(...)`, in `$(...)`
  or in backticks, is refused, unless `allow_compound: true` lets regex rules
  allow such lines. `check/2` says why a command is refused.

  ## Commands that run other commands

  The policy reads a command line the way the shell does and checks the
  commands that actually run:

    * Wrappers that only change how a command runs are looked through. In
      `timeout 30 pytest -q`, `env CI=1 make`, `FOO=1 make` or `nice -n 5 make`
      the wrapped command must be allowed and the wrapper needs no rule;
      allowing `timeout` or `env` allows nothing else. The same goes for
      `command`, `builtin`, `exec`, `nohup`, `time`, `stdbuf`, `flock`, `chrt`,
      `ionice`, `taskset` and `busybox`.
    * Scripts given as text are read and checked like a command line:
      `sh -c '...'` (and `bash`, `dash`, `ksh` and the other POSIX shells),
      `eval`, `trap`, `alias` and `flock -c`.
    * Commands that run another as a different user, on another host, or once
      per input need a rule of their own, and the command they run must be
      allowed too: `sudo`, `doas`, `setsid`, `ssh` (its remote command),
      `xargs`, `find -exec` (and `-execdir`, `-ok`), `parallel`, `watch` and
      `script`.

  A wrapped command is allowed when a rule allows it on its own, or when the
  rule that allows the whole command spells it out: `"sudo apt-get update"`
  allows that command, while `"sudo"` alone allows nothing. Wrappers nest
  (`sudo timeout 5 sh -c '...'`) up to eight deep.

  Deny rules see every command at every level, also with its leading
  variable assignments stripped and with its words unquoted, so a `"rm "`
  rule catches `sh -c 'rm x'`, `FOO=1 rm x`, `\\rm x`, `'rm' x` and
  `/bin/rm x`.

  ## Code the policy can't read

  Some commands run code that can't be read from the command line. They are
  refused even when a rule for the program matches them:

    * code given inline to an interpreter: `python -c`, `perl -e`, `ruby -e`,
      `node -e`, `php -r`, `lua -e`, an `awk` program that calls `system()` or
      uses a pipe, a `sed` script with the `e` command or flag, `vim -c`,
      `emacs --eval`, `make --eval`; git's `-c` and the git, `tar`, `rsync`,
      `scp` and `zip` options that run a command (`rebase --exec`,
      `--to-command`, `-e`);
    * a script read from a file or from standard input: `bash build.sh`,
      `source`, `sh` or `python` with no script, `curl ... | sh`;
    * a command built at run time: `$TOOL args`, `sh -c "$SCRIPT"`,
      `eval "$(...)"`, a command name with a glob or brace expansion, and
      `xargs` or `parallel` handing their input to a wrapper or interpreter;
    * shells with a syntax of their own (`zsh`, `fish`, `csh`, `pwsh`) and
      programs that run commands in a form the policy doesn't read (`strace`,
      `gdb`, `su`, `chroot`, `tmux`, `at`, ...);
    * setting a variable that makes programs run or load other code (`PATH`,
      `LD_PRELOAD`, `BASH_ENV`, `PAGER`, `EDITOR`, `GIT_*`, ...), or setting
      any variable to text with spaces or shell syntax in it. `*`, `?` and
      `[...]` count as text in an assignment before a command, where no shell
      expands them (`DEBUG=* npm test`), and in quotes; unquoted in an
      argument of `env`, `export` or another command, shells can expand them
      to file names, so they're refused there;
    * bash arithmetic on variables (`$((x))`, `let`, `[[ $x -eq 1 ]]`), which
      runs any command substitution stored in the variable.

  To allow one, write an allow rule that spells out the part the policy can't
  read: `"python -c"` allows inline Python, `"bash scripts/ci.sh"` runs that
  script, `~r/\\Ash -c "\\$SCRIPT"\\z/` allows that exact line, while `"python"`
  or `"bash"` alone don't. Or set `allow_opaque: true`, which lets ordinary
  rules allow such commands. Deny rules can't see inside them either way.

  ## A policy is a guard rail, not a sandbox

  The policy reads a command line; it can't see what a command does once it
  runs. Out of its sight are:

    * what a program does with files: the code in a script, a `Makefile`, a
      test suite or a package's scripts, configuration such as git aliases and
      hooks, and files an earlier command wrote;
    * the options of an allowed program that run other commands, beyond those
      listed above, such as `docker run`, `npx` or a database client's shell
      escape;
    * a program copied or linked under another name (`cp /bin/rm ./x`).

  Keep `:allow` rules narrow, treat `:deny` rules as a backstop, and run
  untrusted work in a real sandbox (Docker or a hosted provider, see
  `BeamWeaver.Sandbox`) rather than relying on a policy alone.

  ## Environment

  Commands start from a minimal environment: `PATH`, `HOME`, `LANG`, the
  `LC_*` variables, `TMPDIR`, `USER` and `SHELL`, plus the variables in
  `:env`. Pass `inherit_env: true` to give them your application's whole
  environment instead.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.MapAccess
  alias BeamWeaver.ShellPolicy.Commands
  alias BeamWeaver.ShellPolicy.Parser
  alias BeamWeaver.ShellPolicy.Parser.Command

  # How many wrappers and scripts deep the policy follows a command.
  @max_depth 8

  # Commands an allow rule must not match for it to spell out a wrapped
  # command or the part of a command the policy can't read.
  @probes ["x", "beam_weaver_probe"]

  # `env` can carry credentials meant only for the commands.
  @derive {Inspect, except: [:env]}
  defstruct allow: [],
            deny: [],
            allow_compound: false,
            allow_opaque: false,
            cwd: nil,
            env: %{},
            inherit_env: false,
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
    :allow_compound,
    :allow_opaque,
    :cwd,
    :env,
    :inherit_env,
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
          allow_compound: boolean(),
          allow_opaque: boolean(),
          cwd: Path.t() | nil,
          env: map(),
          inherit_env: boolean(),
          timeout: timeout(),
          max_output_bytes: pos_integer(),
          stderr: stderr_policy(),
          empty_output: String.t() | nil,
          truncation_indicator: String.t() | true | nil,
          redactions: [{Regex.t(), String.t()}],
          executor: module() | struct()
        }

  # Options removed from the API, with what to do instead. `struct/2` would
  # drop an unknown key silently, so a policy written for the old API could
  # leave secrets exposed; `new/1` names these instead.
  @removed_options %{
    env_allowlist: "has been removed; put only the variables commands need in env:"
  }

  def new(opts \\ [])
  def new(%__MODULE__{} = policy), do: validate(policy)
  def new(opts) when is_list(opts), do: opts |> Map.new() |> new()

  def new(opts) when is_map(opts) do
    with :ok <- validate_keys(opts) do
      %__MODULE__{}
      |> struct(normalize_keys(opts))
      |> validate()
    end
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

      not is_boolean(policy.allow_compound) ->
        invalid("allow_compound must be a boolean")

      not is_boolean(policy.allow_opaque) ->
        invalid("allow_opaque must be a boolean")

      not valid_env?(policy.env) ->
        invalid("env must be a map of variable names to values")

      not is_boolean(policy.inherit_env) ->
        invalid("inherit_env must be a boolean")

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
           | env: Map.new(policy.env, fn {name, value} -> {to_string(name), value} end),
             executor: policy.executor || default_executor(),
             redactions: normalize_redactions(policy.redactions)
         }}
    end
  end

  @doc """
  Returns whether the policy allows `command`. See `check/2` for the reason
  it doesn't.
  """
  @spec allowed?(t(), String.t()) :: boolean()
  def allowed?(%__MODULE__{} = policy, command) when is_binary(command), do: check(policy, command) == :ok

  @doc """
  Checks `command` against the policy.

  Returns `:ok`, or `{:error, %BeamWeaver.Core.Error{type: :shell_command_rejected}}`
  whose message says why: no allow rule matches a command it runs, a deny rule
  matches one, or it runs code the policy can't read.
  """
  @spec check(t(), String.t()) :: :ok | {:error, Error.t()}
  def check(%__MODULE__{} = policy, command) when is_binary(command) do
    with {:ok, line} <- read_line(command, 0),
         :ok <- check_deny(policy, line),
         :ok <- allow_line(policy, line) do
      :ok
    else
      {:refuse, reason} ->
        {:error,
         Error.new(:shell_command_rejected, "shell command is not allowed: " <> describe(reason), %{command: command})}
    end
  end

  ## Reading a command line

  # A line and, for each command in it, what the command runs: the tree that
  # both rule kinds walk. An inner item keeps its `region` (where it sits in
  # the command that runs it) and its command, its line, or why it can't be
  # read.
  defp read_line(text, depth) do
    case Parser.parse(text) do
      {:ok, line} ->
        {:ok, %{text: text, single?: line.single?, commands: Enum.map(line.commands, &read_command(&1, depth))}}

      {:error, reason} ->
        {:refuse, {:unreadable, reason}}
    end
  end

  defp read_command(%Command{} = command, depth) do
    analysis = Commands.analyze(command)

    inner =
      case analysis do
        {:inner, _mode, items} -> Enum.map(items, &read_item(&1, depth + 1))
        _plain_or_opaque -> []
      end

    %{command: command, text: Command.text(command), analysis: analysis, inner: inner}
  end

  defp read_item({_kind, _value, region}, depth) when depth > @max_depth,
    do: %{region: region, refusal: {:refuse, :too_deep}}

  defp read_item({:command, command, region}, depth), do: %{region: region, command: read_command(command, depth)}

  defp read_item({:line, text, region}, depth) do
    case read_line(text, depth) do
      {:ok, line} -> %{region: region, line: line}
      {:refuse, _reason} = refusal -> %{region: region, refusal: refusal}
    end
  end

  ## Deny rules

  # Deny rules are checked against every line (the command line and each
  # script inside it) and every command at every level: as written, without
  # its leading assignments, and with its words unquoted.
  defp check_deny(%__MODULE__{deny: []}, _line), do: :ok

  defp check_deny(%__MODULE__{deny: deny}, line) do
    targets = line |> deny_targets([]) |> Enum.uniq()

    if Enum.any?(deny, &deny_rule_match?(&1, targets)),
      do: {:refuse, :denied},
      else: :ok
  end

  defp deny_targets(line, acc), do: Enum.reduce(line.commands, [line.text | acc], &command_targets/2)

  defp command_targets(node, acc) do
    Enum.reduce(node.inner, Commands.texts(node.command) ++ acc, fn
      %{command: inner}, acc -> command_targets(inner, acc)
      %{line: line}, acc -> deny_targets(line, acc)
      %{refusal: _refusal}, acc -> acc
    end)
  end

  defp deny_rule_match?(%Regex{} = regex, targets), do: Enum.any?(targets, &Regex.match?(regex, &1))
  defp deny_rule_match?(prefix, targets), do: Enum.any?(targets, &prefix_match?(prefix, &1))

  ## Allow rules

  defp allow_line(_policy, %{commands: []}), do: :ok
  defp allow_line(policy, %{single?: true, commands: [node]}), do: allow_command(policy, node)

  # A line of several commands needs a regex rule that matches all of it and
  # `allow_compound: true`; that rule allows each plain command in it, and
  # each command a wrapper in it runs must be allowed too.
  defp allow_line(policy, line) do
    rules =
      if policy.allow_compound, do: Enum.filter(policy.allow, &(regex?(&1) and Regex.match?(&1, line.text))), else: []

    if rules == [],
      do: {:refuse, {:compound, line.text}},
      else: first_refusal(line.commands, &allow_member(policy, &1, rules, line.text))
  end

  defp allow_member(policy, node, rules, line_text) do
    # Regions locate a command inside the line, except for a command read
    # from backtick text, which has its own.
    base = if node.command.in_line?, do: 0

    case node.analysis do
      :plain -> :ok
      {:inner, _mode, _items} -> covered(policy, node.inner, rules, line_text, base)
      {:opaque, region, reason} -> opaque(policy, rules, line_text, base && shift(region, base), {reason, node.text})
    end
  end

  # A single command is allowed by the rules that match its text; what it
  # runs must be allowed too.
  defp allow_command(policy, node) do
    rules = Enum.filter(policy.allow, &rule_match?(&1, node.text))
    base = node.command.start

    case node.analysis do
      # A transparent wrapper needs no rule: the commands it runs do.
      {:inner, :transparent, _items} -> covered(policy, node.inner, rules, node.text, base)
      _analysis when rules == [] -> {:refuse, {:not_allowed, node.text}}
      :plain -> :ok
      {:inner, :host, _items} -> covered(policy, node.inner, rules, node.text, base)
      {:opaque, region, reason} -> opaque(policy, rules, node.text, shift(region, base), {reason, node.text})
    end
  end

  # A command's inner commands are covered when each is allowed on its own,
  # or when one of `rules` (which match `text`, the command's text or its
  # line's) spells out every inner command that isn't.
  defp covered(policy, items, rules, text, base) do
    results = Enum.map(items, &allow_item(policy, &1))

    cond do
      Enum.all?(results, &(&1 == :ok)) ->
        :ok

      base != nil and Enum.any?(rules, &spells_out_failed?(&1, items, results, text, base)) ->
        :ok

      true ->
        Enum.find(results, &(&1 != :ok))
    end
  end

  defp spells_out_failed?(rule, items, results, text, base) do
    items
    |> Enum.zip(results)
    |> Enum.all?(fn {item, result} -> result == :ok or spells_out?(rule, text, shift(item.region, base)) end)
  end

  defp allow_item(_policy, %{refusal: refusal}), do: refusal
  defp allow_item(policy, %{command: node}), do: allow_command(policy, node)
  defp allow_item(policy, %{line: line}), do: allow_line(policy, line)

  defp opaque(policy, rules, text, region, {reason, command_text}) do
    cond do
      policy.allow_opaque -> :ok
      region != nil and Enum.any?(rules, &spells_out?(&1, text, region)) -> :ok
      true -> {:refuse, {:opaque, reason, command_text}}
    end
  end

  # A rule spells out the part of `text` at `region` when it stops matching
  # once that part is replaced by another command: `"sudo apt-get"` spells
  # out `apt-get update` in `sudo apt-get update`, `"sudo"` doesn't.
  defp spells_out?(rule, text, {start, stop}) do
    before = binary_part(text, 0, start)
    rest = binary_part(text, stop, byte_size(text) - stop)

    Enum.all?(@probes, fn probe ->
      probed = if start == stop, do: before <> " " <> probe <> rest, else: before <> probe <> rest
      not rule_match?(rule, probed)
    end)
  end

  defp shift({start, stop}, base), do: {start - base, stop - base}

  defp first_refusal(nodes, fun) do
    Enum.reduce_while(nodes, :ok, fn node, :ok ->
      case fun.(node) do
        :ok -> {:cont, :ok}
        refusal -> {:halt, refusal}
      end
    end)
  end

  defp regex?(rule), do: match?(%Regex{}, rule)
  defp rule?(rule), do: is_binary(rule) or regex?(rule)

  defp rule_match?(%Regex{} = regex, text), do: Regex.match?(regex, text)
  defp rule_match?(prefix, text), do: prefix_match?(prefix, text)

  # The rule's trailing whitespace stands for "a word boundary follows", so
  # `"rm "` matches `rm`, `rm x` and `rm\tx` but never `rmdir`: a model can't
  # dodge a `"rm "` deny rule by separating the arguments with a tab.
  defp prefix_match?(prefix, command) do
    core = String.trim_trailing(prefix)
    core_size = byte_size(core)

    cond do
      core == "" ->
        true

      not String.starts_with?(command, core) ->
        false

      byte_size(command) == core_size ->
        true

      true ->
        command
        |> binary_part(core_size, byte_size(command) - core_size)
        |> String.first()
        |> whitespace?()
    end
  end

  defp whitespace?(value) when value in [" ", "\t", "\n", "\r"], do: true
  defp whitespace?(_value), do: false

  defp describe(:denied), do: "it matches a deny rule"
  defp describe(:too_deep), do: "it nests commands more than #{@max_depth} levels deep"
  defp describe({:unreadable, reason}), do: "it can't be read reliably (#{humanize(reason)})"
  defp describe({:not_allowed, text}), do: "no allow rule matches `#{text}`"

  defp describe({:compound, _text}),
    do: "it runs more than one command, which only a regex allow rule with allow_compound: true can allow"

  defp describe({:opaque, reason, text}), do: "`#{text}` runs code the policy can't read (#{humanize(reason)})"

  defp humanize(reason), do: reason |> Atom.to_string() |> String.replace("_", " ")

  ## Validation

  defp valid_env?(env) when is_map(env) or is_list(env),
    do: Enum.all?(env, &match?({name, _value} when is_binary(name) or is_atom(name), &1))

  defp valid_env?(_env), do: false

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

  defp validate_keys(opts) do
    unknown =
      opts
      |> Map.keys()
      |> Enum.map(&canonical_key/1)
      |> Enum.reject(&(&1 in @fields))
      |> Enum.uniq()

    if unknown == [], do: :ok, else: invalid(unknown_message(unknown))
  end

  defp canonical_key(key) when is_atom(key), do: key

  defp canonical_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp canonical_key(key), do: key

  defp unknown_message(unknown) do
    details =
      Enum.map_join(unknown, "; ", fn key ->
        case Map.get(@removed_options, key) do
          nil -> "unknown option #{inspect(key)}"
          hint -> "option #{inspect(key)} #{hint}"
        end
      end)

    "invalid shell policy options: #{details}"
  end

  defp normalize_keys(map) do
    MapAccess.normalize_keys(map, @fields)
  end

  defp default_executor do
    Module.concat([BeamWeaver, Tools, Shell, HostExecutor])
  end

  defp invalid(message), do: {:error, Error.new(:invalid_shell_policy, message)}
end
