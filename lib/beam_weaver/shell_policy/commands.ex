defmodule BeamWeaver.ShellPolicy.Commands do
  @moduledoc false

  # Knows the commands that run other commands, so a policy can check what
  # actually runs. `analyze/1` looks at one simple command and returns:
  #
  #   * `:plain` — a command that runs only itself, as far as the policy can
  #     tell from the command line;
  #   * `{:inner, mode, items}` — a command that runs the commands in `items`:
  #     a command made of some of its words (`timeout 5 make`), or a script
  #     given as text (`sh -c 'make'`). In `:transparent` mode only those
  #     commands need allowing (leading assignments, `env`, `timeout`,
  #     `sh -c`, `eval`); in `:host` mode the command itself needs an allow
  #     rule too (`sudo`, `ssh`, `find -exec`, `xargs`);
  #   * `{:opaque, region, reason}` — a command that runs code the policy
  #     can't read from the command line: inline interpreter code, a script
  #     from a file or standard input, a command built at run time.
  #
  # Regions are `{start, stop}` offsets into the command's source: the part
  # an allow rule must spell out to allow the command without its inner
  # commands being allowed on their own.

  alias BeamWeaver.ShellPolicy.Parser.Command
  alias BeamWeaver.ShellPolicy.Parser.Word

  @type region :: {non_neg_integer(), non_neg_integer()}
  @type item :: {:command, Command.t(), region()} | {:line, binary(), region()}
  @type analysis :: :plain | {:inner, :transparent | :host, [item()]} | {:opaque, region(), atom()}

  # A wrapper named by a path is the system's wrapper only in these
  # directories; `./env` is whatever program sits there.
  @system_dirs ~w(/bin /sbin /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin /opt/homebrew/bin /opt/homebrew/sbin)

  # Words that open a compound command; a wrapped command can start with one
  # (`time { make; }`).
  @reserved ~w(! { if then else elif while until do)

  # Variables that make a shell or another program run a command, or load
  # code from somewhere else, when set. Setting one (before a command, with
  # `env` or with `export`) is refused unless a rule spells it out.
  @dangerous_variables ~w(
    PATH IFS ENV BASH_ENV SHELLOPTS BASHOPTS PS1 PS2 PS3 PS4 PROMPT_COMMAND
    FPATH ZDOTDIR SHELL PAGER MANPAGER EDITOR VISUAL BROWSER LESSOPEN
    LESSCLOSE SSH_ASKPASS SUDO_ASKPASS SUDO_EDITOR PERL5OPT PERL5LIB PERLLIB
    PERL5DB PYTHONPATH PYTHONSTARTUP PYTHONHOME RUBYOPT RUBYLIB NODE_OPTIONS
    NODE_PATH JAVA_TOOL_OPTIONS _JAVA_OPTIONS JDK_JAVA_OPTIONS CLASSPATH
    MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKEFILES RUSTC_WRAPPER RUSTC RUSTFLAGS
    GOFLAGS CC CXX CPP LD AR AS
  )
  @dangerous_prefixes ~w(LD_ DYLD_ GIT_ BASH_FUNC_ CARGO_ npm_config_ NPM_CONFIG_)

  # Shells whose `-c` scripts the policy reads with its POSIX scanner.
  @posix_shells ~w(sh bash dash ash ksh mksh lksh pdksh oksh loksh yash posh rbash)

  # Shells with a syntax of their own: what they run is never read.
  @other_shells ~w(zsh fish csh tcsh pwsh powershell nu elvish xonsh rc es)

  # Programs that run a command given to them in a form the policy doesn't
  # parse, or read commands from standard input.
  @runners ~w(
    strace ltrace valgrind gdb lldb perf xvfb-run dbus-run-session caffeinate
    arch sandbox-exec chroot unshare nsenter firejail bwrap systemd-run runuser
    su sg pkexec screen tmux at batch crontab entr watchexec nodemon hyperfine
    chpst setpriv prlimit numactl cgexec setarch linux32 linux64 proxychains
    proxychains4 torsocks unbuffer rlwrap faketime fakeroot ccache distcc
    chronic ifne pee mispipe run-parts lckdo daemonize start-stop-daemon dtach
    abduco sem systemd-inhibit catchsegv sftp ed red ex iex erl irb jshell
    ghci open xdg-open rsh rexec
  )

  # The options of `conda run` (and mamba's) before its command.
  @conda_run %{args: "np", long_args: ~w(--name --prefix --cwd), long_flags: ~w(--no-capture-output --live-stream)}

  ## Entry point

  @spec analyze(Command.t()) :: analysis()
  def analyze(%Command{words: words} = command) do
    case Enum.find(words, & &1.opaque) do
      %Word{} = word ->
        {:opaque, {word.start, word.stop}, word.opaque}

      nil ->
        case Enum.split_while(words, &assignment?/1) do
          {[], []} -> :plain
          {[], rest} -> command_word(command, rest)
          {assignments, rest} -> assignments(command, assignments, rest)
        end
    end
  end

  # The texts deny rules check for a command: as written, without its leading
  # assignments, and as its unquoted words (with a path-named program also as
  # its bare name), so `"rm "` catches `FOO=1 rm`, `\rm`, `'rm'` and
  # `/bin/rm`. Leading expansions are also dropped, as an empty one vanishes:
  # `$UNSET rm x` runs `rm x`.
  @spec texts(Command.t()) :: [binary()]
  def texts(%Command{words: words} = command) do
    case Enum.drop_while(words, &assignment?/1) do
      [] ->
        [Command.text(command)]

      [first | _others] = rest ->
        stripped = binary_part(command.source, first.start, command.stop - first.start)

        [
          Command.text(command),
          stripped | unquoted_texts(rest) ++ unquoted_texts(Enum.drop_while(rest, &is_nil(&1.value)))
        ]
    end
  end

  defp unquoted_texts([]), do: []

  defp unquoted_texts([first | others] = words) do
    texts = [Enum.map_join(words, " ", & &1.approx), Enum.map_join(words, " ", & &1.bare)]

    if first.value && String.contains?(first.value, "/"),
      do: [Enum.join([Path.basename(first.value) | Enum.map(others, & &1.approx)], " ") | texts],
      else: texts
  end

  # True for a program this module reads specially: given arguments the
  # policy can't see (from `xargs`, say), it could run anything.
  defp special?(name),
    do: name in @posix_shells or name in @other_shells or name in @runners or Map.has_key?(handlers(), name)

  # `python3.12`, `perl5.36` and `lua5.4` behave like `python`, `perl` and
  # `lua`.
  defp canonical(name) do
    cond do
      special?(name) -> name
      (stripped = String.replace(name, ~r/[\d.]+\z/, "")) != "" and special?(stripped) -> stripped
      true -> name
    end
  end

  ## Assignments

  defp assignment?(%Word{raw: raw}), do: Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*(\[[^\]]*\])?\+?=/, raw)

  defp assignments(command, assignments, rest) do
    case Enum.find_value(assignments, &assignment_problem/1) do
      {word, reason} -> {:opaque, {word.start, word.stop}, reason}
      nil when rest == [] -> :plain
      nil -> transparent(command, rest)
    end
  end

  # An assignment is fine when it gives an ordinary variable plain text. A
  # value with shell syntax or spaces in it can become a command for a
  # program that runs the variable (`CC`, a pager), or code for bash
  # arithmetic on it. Glob characters (`*`, `?`, `[`) are plain text in a
  # value that gets this far: where the shell would expand them, as in
  # `env DEBUG=*`, the word has no value.
  defp assignment_problem(%Word{value: nil} = word), do: {word, :dynamic_assignment}

  defp assignment_problem(%Word{value: value} = word) do
    [name, assigned] = String.split(value, "=", parts: 2)
    name = String.trim_trailing(name, "+")

    cond do
      String.contains?(name, "[") -> {word, :array_subscript}
      dangerous_variable?(name) -> {word, :dangerous_variable}
      not plain_value?(assigned) -> {word, :assignment_value}
      true -> nil
    end
  end

  defp dangerous_variable?(name),
    do: name in @dangerous_variables or String.starts_with?(name, @dangerous_prefixes)

  defp plain_value?(value), do: Regex.match?(~r/\A[A-Za-z0-9_.,:\/@%+=~^*?\[\]\-\x80-\xff]*\z/, value)

  ## The command word

  defp command_word(command, [%Word{value: nil} = word | _args]),
    do: {:opaque, {word.start, command.stop}, :dynamic_command}

  defp command_word(command, [word | args]) do
    {name, trusted?} = name(word.value)

    cond do
      name in @posix_shells -> if trusted?, do: posix_shell(command, args), else: :plain
      name in @other_shells -> opaque_from(command, args, :other_shell)
      name in @runners -> opaque_from(command, args, :command_runner)
      true -> dispatch(command, name, trusted?, word, args)
    end
  end

  # The program a command word names, and whether it's the system's: a bare
  # name or one under a system directory.
  defp name(value) do
    {name, trusted?} =
      if String.contains?(value, "/"),
        do: {Path.basename(value), Path.dirname(value) in @system_dirs},
        else: {value, true}

    {canonical(name), trusted?}
  end

  defp dispatch(command, name, trusted?, word, args) do
    case Map.fetch(handlers(), name) do
      # A transparent wrapper named by a path outside the system directories
      # isn't the wrapper: it's whatever program sits there.
      {:ok, {:transparent, handler}} -> if trusted?, do: handler.(command, args), else: :plain
      {:ok, {:builtin, handler}} -> if String.contains?(word.value, "/"), do: :plain, else: handler.(command, args)
      {:ok, {:program, handler}} -> handler.(command, args)
      :error -> :plain
    end
  end

  defp handlers do
    %{
      # Prefix wrappers: only the command they wrap needs allowing.
      "env" => {:transparent, &env/2},
      "genv" => {:transparent, &env/2},
      "command" => {:transparent, &command_builtin/2},
      "builtin" => {:builtin, &transparent/2},
      "exec" => {:transparent, &exec/2},
      "nohup" => {:transparent, &nohup/2},
      "gnohup" => {:transparent, &nohup/2},
      "time" => {:transparent, &time/2},
      "nice" => {:transparent, &nice/2},
      "gnice" => {:transparent, &nice/2},
      "timeout" => {:transparent, &timeout/2},
      "gtimeout" => {:transparent, &timeout/2},
      "stdbuf" => {:transparent, &stdbuf/2},
      "gstdbuf" => {:transparent, &stdbuf/2},
      "flock" => {:transparent, &flock/2},
      "chrt" => {:transparent, &chrt/2},
      "ionice" => {:transparent, &ionice/2},
      "taskset" => {:transparent, &taskset/2},
      "busybox" => {:transparent, &busybox/2},
      "toybox" => {:transparent, &busybox/2},
      # Builtins whose arguments are shell code, or that bash evaluates.
      "eval" => {:builtin, &eval/2},
      "trap" => {:builtin, &trap/2},
      "alias" => {:builtin, &alias_command/2},
      "source" => {:builtin, &opaque_from(&1, &2, :script_file)},
      "." => {:builtin, &opaque_from(&1, &2, :script_file)},
      "fc" => {:builtin, &opaque_from(&1, &2, :history)},
      "coproc" => {:builtin, &opaque_from(&1, &2, :coprocess)},
      "let" => {:builtin, &opaque_from(&1, &2, :arithmetic)},
      "hash" => {:builtin, &option_letter(&1, &2, ?p, :hashed_path)},
      "enable" => {:builtin, &option_letter(&1, &2, ?f, :loadable_builtin)},
      "export" => {:builtin, &declaration/2},
      "readonly" => {:builtin, &declaration/2},
      "declare" => {:builtin, &declaration/2},
      "typeset" => {:builtin, &declaration/2},
      "local" => {:builtin, &declaration/2},
      "read" => {:builtin, &variable_names(&1, &2, %{flags: "ers", args: "adinNptu"})},
      "mapfile" =>
        {:builtin, &variable_names(&1, &2, %{flags: "t", args: "cdnOsu", opaque: "C", opaque_reason: :callback})},
      "readarray" =>
        {:builtin, &variable_names(&1, &2, %{flags: "t", args: "cdnOsu", opaque: "C", opaque_reason: :callback})},
      "unset" => {:builtin, &variable_names(&1, &2, %{flags: "fvn"})},
      "getopts" => {:builtin, &getopts/2},
      "printf" => {:program, &printf/2},
      "test" => {:program, &test/2},
      "[" => {:program, &test/2},
      "[[" => {:builtin, &double_bracket/2},
      # Commands that need an allow rule of their own besides the commands
      # they run.
      "sudo" => {:program, &sudo/2},
      "doas" => {:program, &doas/2},
      "setsid" => {:program, &setsid/2},
      "xargs" => {:program, &xargs/2},
      "find" => {:program, &find/2},
      "parallel" => {:program, &parallel/2},
      "watch" => {:program, &watch/2},
      "script" => {:program, &script/2},
      "ssh" => {:program, &ssh/2},
      # Programs with an option that runs a command.
      "scp" => {:program, &scp/2},
      "rsync" => {:program, &rsync/2},
      "tar" => {:program, &tar/2},
      "gtar" => {:program, &tar/2},
      "bsdtar" => {:program, &tar/2},
      "zip" => {:program, &zip/2},
      "make" => {:program, &make/2},
      "gmake" => {:program, &make/2},
      "git" => {:program, &git/2},
      "mix" => {:program, &mix/2},
      # Project and version managers that run a command in their environment.
      "uv" => {:program, &environment_runner(&1, &2, "run", %{})},
      "poetry" => {:program, &environment_runner(&1, &2, "run", %{})},
      "pipenv" => {:program, &environment_runner(&1, &2, "run", %{})},
      "pdm" => {:program, &environment_runner(&1, &2, "run", %{})},
      "hatch" => {:program, &environment_runner(&1, &2, "run", %{})},
      "rye" => {:program, &environment_runner(&1, &2, "run", %{})},
      "conda" => {:program, &environment_runner(&1, &2, "run", @conda_run)},
      "mamba" => {:program, &environment_runner(&1, &2, "run", @conda_run)},
      "micromamba" => {:program, &environment_runner(&1, &2, "run", @conda_run)},
      "bundle" => {:program, &environment_runner(&1, &2, "exec", %{})},
      "npm" => {:program, &environment_runner(&1, &2, "exec", %{})},
      "pnpm" => {:program, &environment_runner(&1, &2, "exec", %{})},
      "rbenv" => {:program, &environment_runner(&1, &2, "exec", %{})},
      "pyenv" => {:program, &environment_runner(&1, &2, "exec", %{})},
      "nodenv" => {:program, &environment_runner(&1, &2, "exec", %{})},
      "asdf" => {:program, &environment_runner(&1, &2, "exec", %{})},
      "direnv" => {:program, &environment_runner(&1, &2, "exec", %{positional: 1})},
      # Interpreters and programs that take code on their command line.
      "python" => {:program, &python/2},
      "pypy" => {:program, &python/2},
      "perl" => {:program, &perl/2},
      "ruby" => {:program, &ruby/2},
      "node" => {:program, &node/2},
      "nodejs" => {:program, &node/2},
      "bun" => {:program, &inline_anywhere(&1, &2, ~w(-e -p --eval --print), fn -> :plain end)},
      "deno" => {:program, &deno/2},
      "php" => {:program, &php/2},
      "lua" => {:program, &lua/2},
      "luajit" => {:program, &lua/2},
      "R" => {:program, &r/2},
      "Rscript" => {:program, &inline_anywhere(&1, &2, ~w(-e), fn -> :plain end)},
      "elixir" => {:program, &inline_anywhere(&1, &2, ~w(-e --eval --rpc-eval), fn -> :plain end)},
      "julia" => {:program, &script_or_inline(&1, &2, ~w(-e -E --eval --print -i))},
      "osascript" => {:program, &script_or_inline(&1, &2, ~w(-e))},
      "expect" => {:program, &script_or_inline(&1, &2, ~w(-c -i))},
      "tclsh" => {:program, &script_or_inline(&1, &2, [])},
      "wish" => {:program, &script_or_inline(&1, &2, [])},
      "dc" => {:program, &script_or_inline(&1, &2, ~w(-e --expression))},
      "awk" => {:program, &awk/2},
      "gawk" => {:program, &awk/2},
      "mawk" => {:program, &awk/2},
      "nawk" => {:program, &awk/2},
      "sed" => {:program, &sed/2},
      "gsed" => {:program, &sed/2},
      "vim" => {:program, &vim/2},
      "vi" => {:program, &vim/2},
      "nvim" => {:program, &vim/2},
      "view" => {:program, &vim/2},
      "vimdiff" => {:program, &vim/2},
      "gvim" => {:program, &vim/2},
      "mvim" => {:program, &vim/2},
      "emacs" =>
        {:program,
         &inline_anywhere(&1, &2, ~w(--eval -eval --execute -execute -f --funcall -funcall), fn -> :plain end)},
      "emacsclient" => {:program, &inline_anywhere(&1, &2, ~w(-e --eval), fn -> :plain end)}
    }
  end

  ## Results

  defp opaque_from(command, [first | _args], reason), do: {:opaque, {first.start, command.stop}, reason}
  defp opaque_from(command, [], reason), do: {:opaque, {command.stop, command.stop}, reason}

  defp opaque_at(command, %Word{start: start}, reason), do: {:opaque, {start, command.stop}, reason}

  # The command made of `words`, from the first one to the end of `command`,
  # past a reserved word that opens a compound command.
  defp inner_command(%Command{} = command, words) do
    case Enum.drop_while(words, &(&1.raw in @reserved)) do
      [] ->
        {:line, "", {command.stop, command.stop}}

      [first | _rest] = words ->
        {:command, %Command{command | start: first.start, words: words}, {first.start, command.stop}}
    end
  end

  defp transparent(_command, []), do: :plain
  defp transparent(command, words), do: {:inner, :transparent, [inner_command(command, words)]}

  defp host(_command, []), do: :plain
  defp host(command, words), do: {:inner, :host, [inner_command(command, words)]}

  # A script given as one word, from the option that introduced it.
  defp script_word(command, %Word{value: nil} = word, _from, _mode), do: opaque_at(command, word, :dynamic_script)

  defp script_word(command, %Word{value: script}, from, mode),
    do: {:inner, mode, [{:line, script, {from, command.stop}}]}

  # A script made of several words, joined with spaces as `eval`, `ssh` and
  # `watch` do.
  defp joined_script(command, [first | _rest] = words, mode) do
    case Enum.find(words, &is_nil(&1.value)) do
      nil -> {:inner, mode, [{:line, Enum.map_join(words, " ", & &1.value), {first.start, command.stop}}]}
      word -> opaque_at(command, word, :dynamic_script)
    end
  end

  defp option?(%Word{value: "-" <> rest}), do: rest != ""
  defp option?(_word), do: false

  ## Option parsing

  # Walks leading options the way getopt does with a "+" option string,
  # stopping at the first operand or after `--`. An option it doesn't know
  # makes the command opaque: it can't tell whether that option takes the
  # next word as its argument, which would change which word is the command.
  #
  # `spec` holds letters (`flags`, `args`, `optional` for options whose
  # argument must be attached, `opaque`, `stop` for options after which
  # nothing runs) and lists of long options (`long_flags`, `long_args`,
  # `long_optional`, `long_opaque`, `long_stop`). The options seen come back
  # as a letter or name for a flag and `{option, value, word}` for one with a
  # value.
  defp options(words, spec), do: options(words, spec, [])

  defp options([], _spec, seen), do: {:ok, seen, []}
  defp options([%Word{value: nil} = word | _rest], _spec, _seen), do: {:opaque, word, :dynamic_option}
  defp options([%Word{value: "--"} | rest], _spec, seen), do: {:ok, seen, rest}

  defp options([%Word{value: "-"} = word | rest], spec, seen) do
    if Map.get(spec, :lone_dash) == :flag,
      do: options(rest, spec, ["-" | seen]),
      else: {:ok, seen, [word | rest]}
  end

  defp options([%Word{value: "--" <> long} = word | rest], spec, seen) do
    {name, value} =
      case String.split(long, "=", parts: 2) do
        [name, value] -> {"--" <> name, value}
        [name] -> {"--" <> name, nil}
      end

    cond do
      name in Map.get(spec, :long_opaque, []) -> {:opaque, word, Map.get(spec, :opaque_reason, :code_option)}
      name in Map.get(spec, :long_stop, []) -> {:stop, word}
      name in Map.get(spec, :long_flags, []) -> options(rest, spec, [name | seen])
      name in Map.get(spec, :long_optional, []) -> options(rest, spec, [{name, value, word} | seen])
      name in Map.get(spec, :long_args, []) and value != nil -> options(rest, spec, [{name, value, word} | seen])
      name in Map.get(spec, :long_args, []) -> option_argument(name, word, rest, spec, seen)
      true -> {:opaque, word, :unknown_option}
    end
  end

  defp options([%Word{value: "-" <> short} = word | rest], spec, seen) do
    if Map.get(spec, :numeric) && Regex.match?(~r/\A\d+\z/, short),
      do: options(rest, spec, seen),
      else: short_options(short, word, rest, spec, seen)
  end

  defp options(words, _spec, seen), do: {:ok, seen, words}

  defp short_options("", _word, rest, spec, seen), do: options(rest, spec, seen)

  defp short_options(<<letter, more::binary>>, word, rest, spec, seen) do
    cond do
      letter in letters(spec, :opaque) -> {:opaque, word, Map.get(spec, :opaque_reason, :code_option)}
      letter in letters(spec, :stop) -> {:stop, word}
      letter in letters(spec, :flags) -> short_options(more, word, rest, spec, [letter | seen])
      letter in letters(spec, :optional) -> options(rest, spec, [{letter, more, word} | seen])
      letter in letters(spec, :args) and more != "" -> options(rest, spec, [{letter, more, word} | seen])
      letter in letters(spec, :args) -> option_argument(letter, word, rest, spec, seen)
      true -> {:opaque, word, :unknown_option}
    end
  end

  # An option's argument in the next word. The option word, not the
  # argument, is the one recorded: a rule that spells out `script -c` allows
  # any command there.
  defp option_argument(_name, _word, [%Word{value: nil} = argument | _rest], _spec, _seen),
    do: {:opaque, argument, :dynamic_option}

  defp option_argument(name, word, [argument | rest], spec, seen),
    do: options(rest, spec, [{name, argument.value, word} | seen])

  defp option_argument(_name, _word, [], _spec, seen), do: {:ok, seen, []}

  defp letters(spec, key), do: spec |> Map.get(key, "") |> :binary.bin_to_list()

  defp option_values(seen, keys), do: for({key, value, word} <- seen, key in keys, do: {value, word})

  defp with_options(command, args, spec, fun) do
    case options(args, spec) do
      {:opaque, word, reason} -> opaque_at(command, word, reason)
      {:stop, _word} -> :plain
      {:ok, seen, operands} -> fun.(seen, operands)
    end
  end

  # The `count` operands a wrapper reads before its command (a timeout's
  # duration, flock's file); a wrapper given fewer runs nothing.
  defp positional(command, operands, count, fun) do
    {taken, rest} = Enum.split(operands, count)

    cond do
      length(taken) < count -> :plain
      word = Enum.find(taken, &is_nil(&1.value)) -> opaque_at(command, word, :dynamic_option)
      true -> fun.(rest)
    end
  end

  ## Prefix wrappers

  @env %{
    opaque_reason: :split_string,
    flags: "i0v",
    args: "uC",
    opaque: "SPLU",
    lone_dash: :flag,
    long_flags: ~w(--ignore-environment --null --debug --list-signal-handling),
    long_args: ~w(--unset --chdir),
    long_optional: ~w(--default-signal --ignore-signal --block-signal),
    long_opaque: ~w(--split-string),
    long_stop: ~w(--help --version)
  }

  defp env(command, args),
    do: with_options(command, args, @env, fn _seen, operands -> env_assignments(command, operands, &transparent/2) end)

  # `env` and `sudo` read `NAME=VALUE` operands before the command.
  defp env_assignments(command, operands, wrap) do
    {assignments, rest} = Enum.split_while(operands, &(&1.value == nil or String.contains?(&1.value, "=")))

    case Enum.find_value(assignments, &assignment_problem/1) do
      {word, reason} -> {:opaque, {word.start, word.stop}, reason}
      nil -> wrap.(command, rest)
    end
  end

  defp command_builtin(command, args),
    do: with_options(command, args, %{flags: "p", stop: "vV"}, fn _seen, operands -> transparent(command, operands) end)

  defp exec(command, args),
    do: with_options(command, args, %{flags: "cl", args: "a"}, fn _seen, operands -> transparent(command, operands) end)

  defp nohup(command, args),
    do:
      with_options(command, args, %{long_stop: ~w(--help --version)}, fn _seen, operands ->
        transparent(command, operands)
      end)

  @time %{
    flags: "aplqvh",
    args: "fo",
    stop: "V",
    long_flags: ~w(--append --portability --quiet --verbose),
    long_args: ~w(--format --output),
    long_stop: ~w(--help --version)
  }

  defp time(command, args),
    do: with_options(command, args, @time, fn _seen, operands -> transparent(command, operands) end)

  @nice %{args: "n", numeric: true, long_args: ~w(--adjustment), long_stop: ~w(--help --version)}

  defp nice(command, args),
    do: with_options(command, args, @nice, fn _seen, operands -> transparent(command, operands) end)

  @timeout %{
    flags: "fpv",
    args: "ks",
    long_flags: ~w(--foreground --preserve-status --verbose),
    long_args: ~w(--kill-after --signal),
    long_stop: ~w(--help --version)
  }

  defp timeout(command, args) do
    with_options(command, args, @timeout, fn _seen, operands ->
      positional(command, operands, 1, &transparent(command, &1))
    end)
  end

  @stdbuf %{args: "ioe", long_args: ~w(--input --output --error), long_stop: ~w(--help --version)}

  defp stdbuf(command, args),
    do: with_options(command, args, @stdbuf, fn _seen, operands -> transparent(command, operands) end)

  @flock %{
    flags: "sxenoFu",
    args: "wE",
    stop: "hV",
    long_flags: ~w(--shared --exclusive --nonblock --nb --close --no-fork --unlock --verbose),
    long_args: ~w(--wait --timeout --conflict-exit-code),
    long_stop: ~w(--help --version)
  }

  # `flock FILE COMMAND...`, or `flock FILE -c SCRIPT`, which runs SCRIPT
  # with a shell.
  defp flock(command, args) do
    with_options(command, args, @flock, fn _seen, operands ->
      positional(command, operands, 1, fn
        [%Word{value: flag} = flag_word, script | _rest] when flag in ["-c", "--command"] ->
          script_word(command, script, flag_word.start, :transparent)

        [%Word{value: flag} = flag_word] when flag in ["-c", "--command"] ->
          opaque_at(command, flag_word, :missing_script)

        rest ->
          transparent(command, rest)
      end)
    end)
  end

  @chrt %{
    flags: "abdfiorRv",
    args: "TPD",
    stop: "pmh",
    long_flags: ~w(--all-tasks --batch --deadline --fifo --idle --other --rr --reset-on-fork --verbose),
    long_args: ~w(--sched-runtime --sched-period --sched-deadline),
    long_stop: ~w(--pid --max --help --version)
  }

  defp chrt(command, args) do
    with_options(command, args, @chrt, fn _seen, operands ->
      positional(command, operands, 1, &transparent(command, &1))
    end)
  end

  @ionice %{
    flags: "t",
    args: "cn",
    stop: "pPuhV",
    long_flags: ~w(--ignore),
    long_args: ~w(--class --classdata),
    long_stop: ~w(--pid --pgid --uid --help --version)
  }

  defp ionice(command, args),
    do: with_options(command, args, @ionice, fn _seen, operands -> transparent(command, operands) end)

  @taskset %{flags: "ac", stop: "phV", long_flags: ~w(--all-tasks --cpu-list), long_stop: ~w(--pid --help --version)}

  defp taskset(command, args) do
    with_options(command, args, @taskset, fn _seen, operands ->
      positional(command, operands, 1, &transparent(command, &1))
    end)
  end

  # `busybox APPLET ...` runs the applet, which may be a shell.
  defp busybox(command, [%Word{value: nil} = applet | _rest]), do: opaque_at(command, applet, :dynamic_command)
  defp busybox(_command, [%Word{value: "-" <> _option} | _rest]), do: :plain
  defp busybox(command, args), do: transparent(command, args)

  ## Shells

  @shell %{
    opaque_reason: :standard_input,
    flags: "abcefhlmnprtuvxBCEPT",
    args: "oO",
    opaque: "iskHD",
    long_flags: ~w(--norc --noprofile --posix --login --restricted --verbose --noediting --pretty-print),
    long_args: ~w(--rcfile --init-file),
    long_opaque: ~w(--debugger --dump-strings --dump-po-strings --wordexp),
    long_stop: ~w(--help --version)
  }

  # `sh -c SCRIPT` is read and checked like a command line. A shell that runs
  # a script file (`bash build.sh`) or reads commands from standard input
  # (`sh`, `bash -s`, `sh -i`) runs code the policy can't see.
  defp posix_shell(command, args) do
    # `+o option` and `+e` turn options off and read the same arguments.
    args = Enum.map(args, &plus_option/1)

    case options(args, @shell) do
      # A script built at run time (`sh -c "$SCRIPT"`): its region starts at
      # the `-c`, like a script given as text.
      {:opaque, word, :dynamic_option} ->
        {:opaque, {c_flag_start(args, word), command.stop}, :dynamic_script}

      {:opaque, word, reason} ->
        opaque_at(command, word, reason)

      {:stop, _word} ->
        :plain

      {:ok, seen, operands} ->
        c_flag? = ?c in seen

        case operands do
          [script | _positional] when c_flag? -> script_word(command, script, c_flag_start(args, script), :transparent)
          [] when c_flag? -> :plain
          [file | _rest] -> opaque_at(command, file, :script_file)
          [] -> opaque_from(command, [], :standard_input)
        end
    end
  end

  defp plus_option(%Word{value: "+" <> letters} = word) when letters != "", do: %{word | value: "-" <> letters}
  defp plus_option(word), do: word

  # A rule that spells out `sh -c` allows any script, so the script's region
  # starts at the `-c` (alone or in a cluster such as `-ec`).
  defp c_flag_start(args, script) do
    case Enum.find(args, &(&1.start < script.start and is_binary(&1.value) and &1.value =~ ~r/\A-[a-zA-Z]*c/)) do
      %Word{start: start} -> start
      nil -> script.start
    end
  end

  ## Builtins

  # `eval` joins its arguments with spaces and runs the result.
  defp eval(command, args) do
    case Enum.drop_while(args, &(&1.value == "--")) do
      [] -> :plain
      words -> joined_script(command, words, :transparent)
    end
  end

  # `trap ACTION SIGNAL...` runs ACTION later.
  defp trap(command, args) do
    case Enum.drop_while(args, &(&1.value == "--")) do
      [%Word{value: nil} = action | _signals] ->
        opaque_at(command, action, :dynamic_script)

      [%Word{value: "-" <> _option} | _rest] ->
        :plain

      [action, _signal | _signals] ->
        if action.value =~ ~r/\A\d+\z/,
          do: :plain,
          else: {:inner, :transparent, [{:line, action.value, {action.start, action.stop}}]}

      _single_or_none ->
        :plain
    end
  end

  # `alias name=TEXT` makes `name` run TEXT.
  defp alias_command(command, args) do
    case Enum.find(args, &is_nil(&1.value)) do
      %Word{} = word ->
        opaque_at(command, word, :dynamic_script)

      nil ->
        items =
          for %Word{value: value} = word <- args,
              [_name, text] <- [String.split(value, "=", parts: 2)],
              do: {:line, text, {word.start, word.stop}}

        if items == [], do: :plain, else: {:inner, :transparent, items}
    end
  end

  # `hash -p PATH NAME` makes NAME run PATH; `enable -f FILE` loads a builtin
  # from a shared library.
  defp option_letter(command, args, letter, reason) do
    case Enum.find(args, &(is_nil(&1.value) or (option?(&1) and letter in :binary.bin_to_list(&1.value)))) do
      nil -> :plain
      word -> opaque_at(command, word, reason)
    end
  end

  # `export`, `declare` and friends: each `NAME=VALUE` is an assignment;
  # bash evaluates `declare -i` values and subscripted names as arithmetic,
  # and `-n` makes a name refer to another variable.
  defp declaration(command, args) do
    Enum.find_value(args, :plain, fn
      %Word{value: nil} = word ->
        opaque_at(command, word, :dynamic_assignment)

      %Word{value: "-" <> letters} = word ->
        if String.contains?(letters, ["i", "n"]), do: opaque_at(command, word, :arithmetic)

      %Word{value: value} = word ->
        cond do
          String.contains?(value, "=") ->
            with {word, reason} <- assignment_problem(word), do: {:opaque, {word.start, word.stop}, reason}

          String.contains?(value, "[") ->
            opaque_at(command, word, :array_subscript)

          true ->
            nil
        end
    end)
  end

  # Builtins that assign to the variables they name: a subscripted name is
  # evaluated as bash arithmetic, and mapfile's `-C` runs a callback.
  defp variable_names(command, args, spec) do
    with_options(command, args, spec, fn seen, operands ->
      names = operands ++ for({?a, _value, word} <- seen, do: word)
      subscripted_name(command, names)
    end)
  end

  defp getopts(command, [_optstring, name | _args]), do: subscripted_name(command, [name])
  defp getopts(_command, _args), do: :plain

  defp subscripted_name(command, names) do
    case Enum.find(names, &(is_nil(&1.value) or String.contains?(&1.value, "["))) do
      nil -> :plain
      %Word{value: nil} = word -> opaque_at(command, word, :dynamic_assignment)
      word -> opaque_at(command, word, :array_subscript)
    end
  end

  defp printf(command, [%Word{value: "-v"}, name | _rest]), do: subscripted_name(command, [name])

  defp printf(command, [%Word{value: "-v" <> name} = word | _rest]),
    do: subscripted_name(command, [%{word | value: name}])

  defp printf(_command, _args), do: :plain

  # `test -v NAME` and `[ -v NAME ]` evaluate a subscripted name.
  defp test(command, args) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(:plain, fn
      [%Word{value: "-v"}, name] ->
        if is_nil(name.value) or name.value =~ "[", do: opaque_at(command, name, :array_subscript)

      _pair ->
        nil
    end)
  end

  # In `[[ ... ]]`, `-eq` and the other arithmetic comparisons evaluate their
  # operands, and the variables they name, as bash arithmetic.
  @arithmetic_tests ~w(-eq -ne -lt -le -gt -ge)

  defp double_bracket(command, args) do
    arithmetic? = Enum.any?(args, &(&1.value in @arithmetic_tests))
    operands = Enum.reject(args, &(&1.value in ["]]", "!" | @arithmetic_tests]))

    if arithmetic? and not Enum.all?(operands, &(is_binary(&1.value) and &1.value =~ ~r/\A-?\d+\z/)),
      do: opaque_from(command, args, :arithmetic),
      else: test(command, args)
  end

  ## Commands that need an allow rule of their own

  @sudo %{
    opaque_reason: :login_shell,
    flags: "AbEHnPSk",
    args: "CDgpRrtTUu",
    opaque: "sieh",
    stop: "lvKV",
    long_flags:
      ~w(--askpass --background --preserve-env --set-home --non-interactive --preserve-groups --stdin --reset-timestamp --bell),
    long_args:
      ~w(--close-from --chdir --group --prompt --chroot --role --type --command-timeout --other-user --user --host),
    long_opaque: ~w(--shell --login --edit),
    long_stop: ~w(--list --validate --remove-timestamp --version --help)
  }

  defp sudo(command, args),
    do: with_options(command, args, @sudo, fn _seen, operands -> env_assignments(command, operands, &host/2) end)

  defp doas(command, args),
    do:
      with_options(
        command,
        args,
        %{flags: "n", args: "au", opaque: "s", stop: "LC", opaque_reason: :login_shell},
        fn _seen, operands -> host(command, operands) end
      )

  @setsid %{flags: "cfw", stop: "hV", long_flags: ~w(--ctty --fork --wait), long_stop: ~w(--help --version)}

  defp setsid(command, args),
    do: with_options(command, args, @setsid, fn _seen, operands -> host(command, operands) end)

  @xargs %{
    flags: "0prtxo",
    args: "adEILnPsJRS",
    optional: "eil",
    long_flags: ~w(--null --interactive --no-run-if-empty --verbose --exit --open-tty --show-limits),
    long_args: ~w(--arg-file --delimiter --max-args --max-procs --max-chars --process-slot-var),
    long_optional: ~w(--eof --replace --max-lines),
    long_stop: ~w(--help --version)
  }

  # xargs adds the words it reads to its command's arguments, or (with `-I`)
  # puts them where the replacement string appears. A wrapper, shell or
  # interpreter given arguments the policy can't see could run anything.
  defp xargs(command, args) do
    with_options(command, args, @xargs, fn seen, operands ->
      replace = replace_string(seen)

      case operands do
        [] ->
          :plain

        [%Word{value: nil} = first | _rest] ->
          opaque_at(command, first, :dynamic_command)

        [first | _rest] ->
          {name, _trusted?} = name(first.value)

          cond do
            replace && String.contains?(first.value, replace) -> opaque_at(command, first, :input_command)
            special?(name) -> opaque_at(command, first, :input_arguments)
            true -> host(command, operands)
          end
      end
    end)
  end

  defp replace_string(seen) do
    case option_values(seen, [?I, ?J, ?i, "--replace"]) do
      [{value, _word} | _rest] when value not in [nil, ""] -> value
      [_default | _rest] -> "{}"
      [] -> nil
    end
  end

  @find_actions ~w(-exec -execdir -ok -okdir)

  # `find ... -exec COMMAND ... ;` runs COMMAND for each file. GNU find puts
  # the file name wherever `{}` appears, even inside a word, so a `{}` in the
  # command's name or inside an argument (a script, say) makes it opaque.
  defp find(command, args) do
    case Enum.find(args, &is_nil(&1.value)) do
      %Word{} = word -> opaque_at(command, word, :dynamic_option)
      nil -> find_actions(command, args, [])
    end
  end

  defp find_actions(_command, [], []), do: :plain
  defp find_actions(_command, [], items), do: {:inner, :host, Enum.reverse(items)}

  defp find_actions(%Command{} = command, [%Word{value: action} = word | rest], items) when action in @find_actions do
    case find_clause(rest, []) do
      {:unterminated, _rest} ->
        opaque_at(command, word, :unterminated_exec)

      {[], _rest} ->
        opaque_at(command, word, :missing_command)

      {[first | _more] = clause, rest} ->
        last = List.last(clause)

        cond do
          String.contains?(first.value, "{}") ->
            opaque_at(command, first, :input_command)

          Enum.any?(clause, &(&1.value != "{}" and String.contains?(&1.value, "{}"))) ->
            opaque_at(command, first, :input_script)

          true ->
            inner = %Command{command | start: first.start, stop: last.stop, words: clause}
            find_actions(command, rest, [{:command, inner, {first.start, last.stop}} | items])
        end
    end
  end

  defp find_actions(command, [_word | rest], items), do: find_actions(command, rest, items)

  defp find_clause([], _acc), do: {:unterminated, []}
  defp find_clause([%Word{value: ";"} | rest], acc), do: {Enum.reverse(acc), rest}
  defp find_clause([%Word{value: "+"} | rest], [%Word{value: "{}"} | _more] = acc), do: {Enum.reverse(acc), rest}
  defp find_clause([word | rest], acc), do: find_clause(rest, [word | acc])

  # GNU parallel runs its command through a shell, with replacement strings
  # such as `{}` for its input. Only the simplest form is read: no options,
  # no replacement strings, and a command that isn't a wrapper or
  # interpreter (the input becomes its arguments).
  defp parallel(command, args) do
    case Enum.split_while(args, &(&1.value not in [":::", "::::", ":::+", "::::+"])) do
      {[], _inputs} ->
        opaque_from(command, [], :standard_input)

      {[first | _rest] = words, _inputs} ->
        cond do
          first.value == nil -> opaque_at(command, first, :dynamic_command)
          option?(first) -> opaque_at(command, first, :unknown_option)
          Enum.any?(words, &(&1.value && String.contains?(&1.value, "{"))) -> opaque_at(command, first, :input_script)
          special?(elem(name(first.value), 0)) -> opaque_at(command, first, :input_arguments)
          true -> joined_script(%{command | stop: List.last(words).stop}, words, :host)
        end
    end
  end

  @watch %{
    flags: "bcCdeghptrwx",
    args: "nqs",
    long_flags: ~w(--beep --color --no-color --errexit --chgexit --precise --no-title --no-rerun --no-wrap --exec),
    long_args: ~w(--interval --equexit --shotsdir),
    long_optional: ~w(--differences),
    long_stop: ~w(--help --version)
  }

  # `watch COMMAND...` joins its operands and runs them with `sh -c`; with
  # `-x` it runs them directly.
  defp watch(command, args) do
    with_options(command, args, @watch, fn seen, operands ->
      cond do
        operands == [] -> :plain
        ?x in seen or "--exec" in seen -> host(command, operands)
        true -> joined_script(command, operands, :host)
      end
    end)
  end

  @script %{
    flags: "aefqFkr",
    args: "cEIOBTmo",
    long_flags: ~w(--append --return --flush --quiet --force),
    long_args: ~w(--command --echo --log-in --log-out --log-io --log-timing --logging-format --output-limit),
    long_stop: ~w(--help --version)
  }

  # util-linux `script -c COMMAND [file]` runs COMMAND with a shell; BSD
  # `script file COMMAND...` runs COMMAND; with neither it starts a shell that
  # reads standard input.
  defp script(command, args) do
    with_options(command, args, @script, fn seen, operands ->
      case {option_values(seen, [?c, "--command"]), operands} do
        {[{script, word} | _rest], _operands} -> {:inner, :host, [{:line, script, {word.start, command.stop}}]}
        {[], [_file | [_ | _] = words]} -> host(command, words)
        {[], _operands} -> opaque_from(command, [], :standard_input)
      end
    end)
  end

  @ssh %{flags: "46AaCfgKkMnqsTtvXxYy", args: "BbcDEeFIiJLlmOoPpRSWw", stop: "GQVN"}

  # `ssh HOST COMMAND...` runs COMMAND on the remote host through its shell,
  # so it's checked like a command line. Without a command the remote shell
  # reads standard input.
  defp ssh(command, args) do
    with_options(command, args, @ssh, fn seen, operands ->
      local_command = Enum.find(option_values(seen, [?o]), fn {value, _word} -> ssh_command_option?(value) end)

      cond do
        local_command -> opaque_at(command, elem(local_command, 1), :command_option)
        option_values(seen, [?O, ?W]) != [] or ?s in seen -> :plain
        operands == [] -> :plain
        hd(operands).value == nil -> opaque_at(command, hd(operands), :dynamic_option)
        match?([_host], operands) -> opaque_from(command, [], :standard_input)
        true -> joined_script(command, tl(operands), :host)
      end
    end)
  end

  # `-o ProxyCommand=...`, `LocalCommand`, `KnownHostsCommand` and
  # `Match exec` run local commands.
  defp ssh_command_option?(value), do: value =~ ~r/command|match/i

  defp scp(command, args) do
    args
    |> Enum.chunk_every(2, 1, [nil])
    |> Enum.find_value(:plain, fn
      [%Word{value: nil} = word, _next] ->
        opaque_at(command, word, :dynamic_option)

      [%Word{value: "-o" <> value} = word, next] ->
        value = if value == "" and next, do: next.value, else: value
        if value == nil or ssh_command_option?(value), do: opaque_at(command, word, :command_option)

      [%Word{value: "-" <> letters} = word, _next] ->
        if not String.starts_with?(letters, "-") and String.contains?(letters, "S"),
          do: opaque_at(command, word, :command_option)

      _pair ->
        nil
    end)
  end

  defp rsync(command, args) do
    Enum.find_value(args, :plain, fn
      %Word{value: nil} = word ->
        opaque_at(command, word, :dynamic_option)

      %Word{value: "--" <> long} = word ->
        if String.starts_with?(long, ["rsh", "rsync-path"]), do: opaque_at(command, word, :command_option)

      %Word{value: "-" <> letters} = word ->
        if String.contains?(letters, "e"), do: opaque_at(command, word, :command_option)

      _word ->
        nil
    end)
  end

  @tar_command_options ~w(--to-command --checkpoint-action --use-compress-program --rsh-command --info-script --new-volume-script)

  defp tar(command, args) do
    args
    |> Enum.with_index()
    |> Enum.find_value(:plain, fn
      {%Word{value: nil} = word, _index} ->
        opaque_at(command, word, :dynamic_option)

      {%Word{value: "--" <> _long = value} = word, _index} ->
        if String.starts_with?(value, @tar_command_options), do: opaque_at(command, word, :command_option)

      {%Word{value: "-" <> letters} = word, _index} ->
        if String.contains?(letters, ["I", "F"]), do: opaque_at(command, word, :command_option)

      # An old-style first argument bundles options without a dash (`tar xzf`).
      {%Word{value: letters} = word, 0} ->
        if letters =~ ~r/\A[A-Za-z]+\z/ and String.contains?(letters, ["I", "F"]),
          do: opaque_at(command, word, :command_option)

      _other ->
        nil
    end)
  end

  defp zip(command, args) do
    Enum.find_value(args, :plain, fn
      %Word{value: nil} = word -> opaque_at(command, word, :dynamic_option)
      %Word{value: "-TT" <> _} = word -> opaque_at(command, word, :command_option)
      %Word{value: "--unzip-command" <> _} = word -> opaque_at(command, word, :command_option)
      _word -> nil
    end)
  end

  # `make --eval TEXT` (`-E`) adds makefile text, `-f -` reads a makefile
  # from standard input, and a `NAME=VALUE` argument overrides a variable a
  # recipe may run.
  defp make(command, args) do
    args
    |> Enum.chunk_every(2, 1, [nil])
    |> Enum.find_value(:plain, fn
      [%Word{value: nil} = word, _next] ->
        opaque_at(command, word, :dynamic_option)

      [%Word{value: "--eval" <> _} = word, _next] ->
        opaque_at(command, word, :inline_code)

      [%Word{value: value} = word, next] when value in ["-f", "--file", "--makefile"] ->
        if next == nil or next.value == "-", do: opaque_at(command, word, :standard_input)

      [%Word{value: value} = word, _next] when value in ["-f-", "--file=-", "--makefile=-"] ->
        opaque_at(command, word, :standard_input)

      [%Word{value: "-" <> letters} = word, _next] ->
        if not String.starts_with?(letters, "-") and String.contains?(letters, "E"),
          do: opaque_at(command, word, :inline_code)

      [%Word{value: value} = word, _next] ->
        if value =~ ~r/\A[^=\s]+=/ do
          with {word, reason} <- assignment_problem(word), do: {:opaque, {word.start, word.stop}, reason}
        end
    end)
  end

  @git_global %{
    opaque_reason: :config_option,
    flags: "pP",
    args: "C",
    opaque: "c",
    long_flags:
      ~w(--bare --no-pager --paginate --no-replace-objects --literal-pathspecs --glob-pathspecs --noglob-pathspecs --icase-pathspecs --no-optional-locks --no-lazy-fetch --no-advice),
    long_args: ~w(--git-dir --work-tree --namespace --list-cmds --attr-source --super-prefix),
    long_opaque: ~w(--config-env --exec-path),
    long_stop: ~w(--version --help --html-path --man-path --info-path)
  }

  # Subcommand options and actions that make git run a command given on its
  # command line.
  @git_command_options %{
    "rebase" => ~w(-x --exec),
    "difftool" => ~w(-x --extcmd),
    "grep" => ~w(-O --open-files-in-pager),
    "clone" => ~w(-u --upload-pack -c --config),
    "fetch" => ~w(--upload-pack),
    "pull" => ~w(--upload-pack),
    "ls-remote" => ~w(-u --upload-pack),
    "push" => ~w(--receive-pack --exec),
    "archive" => ~w(--exec),
    "send-email" => ~w(--sendmail-cmd --smtp-server)
  }
  @git_command_actions %{"bisect" => ~w(run), "submodule" => ~w(foreach)}

  # `git -c NAME=VALUE` sets any configuration, `core.sshCommand` and
  # `alias.x=!cmd` included.
  defp git(command, args) do
    with_options(command, args, @git_global, fn _seen, operands ->
      case operands do
        [] -> :plain
        [%Word{value: nil} = subcommand | _rest] -> opaque_at(command, subcommand, :dynamic_command)
        [%Word{value: "filter-branch"} = subcommand | _rest] -> opaque_at(command, subcommand, :command_option)
        [%Word{value: subcommand} | rest] -> git_subcommand(command, subcommand, rest)
      end
    end)
  end

  defp git_subcommand(command, subcommand, args) do
    options = Map.get(@git_command_options, subcommand, [])
    actions = Map.get(@git_command_actions, subcommand, [])

    if options == [] and actions == [] do
      :plain
    else
      Enum.find_value(args, :plain, fn
        %Word{value: nil} = word ->
          opaque_at(command, word, :dynamic_option)

        %Word{value: value} = word ->
          if value in actions or Enum.any?(options, &git_option?(value, &1)),
            do: opaque_at(command, word, :command_option)
      end)
    end
  end

  defp git_option?(value, "--" <> _long = option), do: value == option or String.starts_with?(value, option <> "=")

  defp git_option?(value, "-" <> _short = option),
    do: String.starts_with?(value, option) and not String.starts_with?(value, "--")

  # `poetry run CMD`, `bundle exec CMD`, `npm exec CMD` and the like run CMD
  # in the project's environment: CMD must be allowed, and so must the
  # runner. Options before the subcommand, or options of `run`/`exec` the
  # policy doesn't know, make it opaque, since they can take the next word.
  defp environment_runner(command, args, subcommand, spec) do
    {options, rest} = Enum.split_while(args, &option?/1)

    case rest do
      [%Word{value: nil} = word | _rest] ->
        opaque_at(command, word, :dynamic_command)

      [%Word{value: ^subcommand} | inner] when options == [] ->
        with_options(command, inner, spec, fn _seen, operands ->
          positional(command, operands, Map.get(spec, :positional, 0), &host(command, &1))
        end)

      [%Word{value: ^subcommand} | _inner] ->
        opaque_at(command, hd(options), :unknown_option)

      _other ->
        :plain
    end
  end

  # `mix run -e CODE` and `mix eval CODE`.
  defp mix(command, [%Word{value: "eval"} = subcommand | _rest]), do: opaque_at(command, subcommand, :inline_code)

  defp mix(command, [%Word{value: "run"} | rest]),
    do: inline_anywhere(command, rest, ~w(-e --eval), fn -> :plain end)

  defp mix(_command, _args), do: :plain

  ## Interpreters

  # Reads an interpreter's options, letter by letter where they cluster
  # (`-pe`, `-lane`). An inline-code option makes the command opaque, and so
  # does reading the program from standard input (no script operand, or
  # `-`). `spec`: letters for `inline` code, `opaque` modes (interactive),
  # `stop` (`python -m`, `-V`: what follows isn't a program for the
  # interpreter), `attached` options whose value is the rest of the word,
  # `args` options that take the next word when nothing follows them,
  # `digits` options followed by an optional number (perl's `-l0`, `-0777`,
  # after which the cluster goes on: `-lane`), `one` options followed by one
  # letter (ruby's `-Ku`), and `flags`; long options as `long_inline`,
  # `long_args`, `long_flags`, `long_stop`. An unknown option makes the
  # command opaque, unless `unknown_long: :flag`.
  defp interpreter(command, args, spec) do
    case interpreter_options(args, spec) do
      {:opaque, word, reason} -> opaque_at(command, word, reason)
      :script -> :plain
      :standard_input -> opaque_from(command, [], :standard_input)
    end
  end

  defp interpreter_options([], _spec), do: :standard_input
  defp interpreter_options([%Word{value: nil} = word | _rest], _spec), do: {:opaque, word, :dynamic_option}
  defp interpreter_options([%Word{value: "-"} = word | _rest], _spec), do: {:opaque, word, :standard_input}
  defp interpreter_options([%Word{value: "--"}], _spec), do: :standard_input
  defp interpreter_options([%Word{value: "--"} | _rest], _spec), do: :script

  defp interpreter_options([%Word{value: "--" <> _long = value} = word | rest], spec) do
    [name | value?] = String.split(value, "=", parts: 2)

    cond do
      name in Map.get(spec, :long_inline, []) -> {:opaque, word, :inline_code}
      name in Map.get(spec, :long_stop, []) -> :script
      name in Map.get(spec, :long_args, []) and value? == [] -> interpreter_options(Enum.drop(rest, 1), spec)
      name in Map.get(spec, :long_args, []) or name in Map.get(spec, :long_flags, []) -> interpreter_options(rest, spec)
      Map.get(spec, :unknown_long) == :flag -> interpreter_options(rest, spec)
      true -> {:opaque, word, :unknown_option}
    end
  end

  defp interpreter_options([%Word{value: "-" <> letters} = word | rest], spec),
    do: interpreter_letters(letters, word, rest, spec)

  defp interpreter_options([_script | _rest], _spec), do: :script

  defp interpreter_letters("", _word, rest, spec), do: interpreter_options(rest, spec)

  defp interpreter_letters(<<letter, more::binary>>, word, rest, spec) do
    cond do
      letter in letters(spec, :inline) -> {:opaque, word, :inline_code}
      letter in letters(spec, :opaque) -> {:opaque, word, Map.get(spec, :opaque_reason, :interactive)}
      letter in letters(spec, :stop) -> :script
      letter in letters(spec, :attached) -> interpreter_options(rest, spec)
      letter in letters(spec, :args) and more == "" -> interpreter_options(Enum.drop(rest, 1), spec)
      letter in letters(spec, :args) -> interpreter_options(rest, spec)
      letter in letters(spec, :digits) -> interpreter_letters(skip_number(letter, more), word, rest, spec)
      letter in letters(spec, :one) -> interpreter_letters(drop_one(more), word, rest, spec)
      letter in letters(spec, :flags) -> interpreter_letters(more, word, rest, spec)
      true -> {:opaque, word, :unknown_option}
    end
  end

  # A number (perl's `-0` also takes `x` and hex digits), perl's debugger
  # `-dt`/`-d:Module`, or a `:category` that runs to the end of the word
  # (ruby's `-W:no-deprecated`).
  defp skip_number(?0, "x" <> hex), do: String.replace(hex, ~r/\A[0-9a-fA-F]*/, "")
  defp skip_number(?d, "t" <> more), do: skip_number(?d, more)
  defp skip_number(_letter, ":" <> _value), do: ""
  defp skip_number(_letter, more), do: String.replace(more, ~r/\A[0-9]*/, "")

  defp drop_one(<<_letter, more::binary>>), do: more
  defp drop_one(""), do: ""

  # Opaque when any word, anywhere, is one of `flags` (or `flag=...`): a
  # safety net for an option whose argument the option parse misread as the
  # script.
  defp inline_anywhere(command, args, flags, fun) do
    assigned = Enum.map(flags, &(&1 <> "="))

    case Enum.find(args, &(is_binary(&1.value) and (&1.value in flags or String.starts_with?(&1.value, assigned)))) do
      nil -> fun.()
      word -> opaque_at(command, word, :inline_code)
    end
  end

  defp python(command, args) do
    interpreter(command, args, %{
      inline: "c",
      opaque: "i",
      stop: "mVh",
      args: "WXQ",
      flags: "bBdEIOPqsSuvxR",
      long_args: ~w(--check-hash-based-pycs),
      long_stop: ~w(--help --version --help-env --help-xoptions --help-all)
    })
  end

  # perl's `-e`/`-E` take code, and `-M`/`-m` load a module from text that
  # can carry code (`-M'strict;system(...)'`). `-lane` and `-de` cluster:
  # `-l` and `-d` take an optional value and the letters after it go on.
  defp perl(command, args) do
    interpreter(command, args, %{
      inline: "eEMm",
      opaque: "D",
      opaque_reason: :debugger,
      stop: "vVh",
      args: "I",
      attached: "iFxC",
      digits: "l0d",
      flags: "acfnpsStTuUwWX",
      long_stop: ~w(--version --help)
    })
  end

  defp ruby(command, args) do
    interpreter(command, args, %{
      inline: "e",
      stop: "vh",
      attached: "Fix",
      args: "CEIr",
      digits: "0TW",
      one: "K",
      flags: "acdlnpsSUwy",
      long_flags: ~w(--verbose --jit --yjit --rjit --disable-gems),
      long_stop: ~w(--version --help --copyright)
    })
  end

  @node_inline ~w(-e -p -pe -ep --eval --print)

  defp node(command, args) do
    inline_anywhere(command, args, @node_inline, fn ->
      interpreter(command, args, %{
        inline: "ep",
        opaque: "i",
        stop: "vh",
        args: "rC",
        flags: "c",
        long_inline: ~w(--eval --print --interactive),
        long_args:
          ~w(--require --import --loader --experimental-loader --conditions --input-type --title --env-file --inspect-port --watch-path --test-reporter --test-reporter-destination --redirect-warnings --report-dir --cpu-prof-dir --heap-prof-dir --diagnostic-dir --icu-data-dir --openssl-config --disable-warning),
        long_stop: ~w(--version --help --run),
        unknown_long: :flag
      })
    end)
  end

  defp deno(command, [%Word{value: subcommand} = word | _rest]) when subcommand in ["eval", "repl"],
    do: opaque_at(command, word, :inline_code)

  defp deno(command, [%Word{value: "run"} | rest]) do
    case Enum.find(rest, &(&1.value == "-")) do
      nil -> :plain
      word -> opaque_at(command, word, :standard_input)
    end
  end

  defp deno(command, []), do: opaque_from(command, [], :standard_input)
  defp deno(_command, _args), do: :plain

  defp php(command, args) do
    interpreter(command, args, %{
      inline: "rBRE",
      opaque: "a",
      stop: "vhimS",
      args: "cdfzt",
      flags: "CeHlnqsw",
      long_stop: ~w(--version --help --ini)
    })
  end

  defp lua(command, args),
    do: interpreter(command, args, %{inline: "e", opaque: "i", args: "l", flags: "vEW", long_stop: ~w(--version)})

  # `R -e EXPR` runs code; `R` with no script (`R --vanilla < file`) reads it
  # from standard input. `R CMD ...` and `R -f FILE` run files.
  defp r(_command, [%Word{value: "CMD"} | _rest]), do: :plain

  defp r(command, args) do
    inline_anywhere(command, args, ~w(-e), fn ->
      if Enum.any?(
           args,
           &(&1.value in ~w(-f --version --help) or (is_binary(&1.value) and String.starts_with?(&1.value, "--file=")))
         ),
         do: :plain,
         else: opaque_from(command, args, :standard_input)
    end)
  end

  # A program that runs a script file, code given with one of `inline`, or
  # (with no operand) code from standard input.
  defp script_or_inline(command, args, inline) do
    inline_anywhere(command, args, inline, fn ->
      cond do
        Enum.any?(args, &(&1.value in ~w(--version --help -v -V -h))) -> :plain
        Enum.any?(args, &(is_binary(&1.value) and not option?(&1))) -> :plain
        true -> opaque_from(command, args, :standard_input)
      end
    end)
  end

  # `vim -c CMD`, `+CMD`, `--cmd CMD` and `--remote-send` run editor commands
  # (`:!rm ...`); `-e`/`-E` (ex mode) read them from standard input.
  defp vim(command, args) do
    Enum.find_value(args, :plain, fn
      %Word{value: nil} = word ->
        opaque_at(command, word, :dynamic_option)

      %Word{value: value} = word ->
        if value in ~w(--cmd -e -E -es -Es -se -sE) or String.starts_with?(value, ["+", "-c", "--remote"]),
          do: opaque_at(command, word, :inline_code)
    end)
  end

  @awk %{
    args: "vFfeEilW",
    optional: "dDLop",
    flags: "bcCgMnNOPrsStVhy",
    long_args: ~w(--assign --field-separator --file --source --exec --include --load),
    long_optional: ~w(--dump-variables --debug --lint --pretty-print --profile),
    long_flags:
      ~w(--sandbox --characters-as-bytes --traditional --copyright --gen-pot --help --use-lc-numeric --bignum --non-decimal-data --optimize --posix --re-interval --no-optimize --lint-old --version --csv)
  }

  # An awk program can run commands with `system()`, pipes (`print | "sh"`,
  # `"cmd" | getline`) and gawk's indirect calls (`@name()`).
  defp awk(command, args) do
    with_options(command, args, @awk, fn seen, operands ->
      sources = for {source, _word} <- option_values(seen, [?e, "--source"]), do: source
      files = for {file, _word} <- option_values(seen, [?f, ?E, "--file", "--exec"]), do: file

      programs =
        cond do
          ?S in seen or "--sandbox" in seen -> []
          sources != [] or files != [] -> sources
          operands != [] -> [hd(operands).value]
          true -> []
        end

      cond do
        "-" in files and not (?S in seen or "--sandbox" in seen) -> opaque_from(command, args, :standard_input)
        nil in programs -> opaque_from(command, args, :dynamic_script)
        Enum.any?(programs, &awk_runs_commands?/1) -> opaque_from(command, args, :inline_code)
        true -> :plain
      end
    end)
  end

  defp awk_runs_commands?(program),
    do: String.contains?(program, ["system", "@"]) or String.contains?(String.replace(program, "||", ""), "|")

  @sed %{
    flags: "nrEsuz",
    args: "efl",
    optional: "i",
    long_flags:
      ~w(--quiet --silent --regexp-extended --separate --unbuffered --null-data --zero-terminated --posix --debug --follow-symlinks --binary --sandbox),
    long_args: ~w(--expression --file --line-length),
    long_optional: ~w(--in-place),
    long_stop: ~w(--help --version)
  }

  # GNU sed's `e` command and the `e` flag of `s` run commands.
  defp sed(command, args) do
    with_options(command, args, @sed, fn seen, operands ->
      expressions = for {expression, _word} <- option_values(seen, [?e, "--expression"]), do: expression
      files = for {file, _word} <- option_values(seen, [?f, "--file"]), do: file

      scripts =
        cond do
          "--sandbox" in seen -> []
          expressions != [] or files != [] -> expressions
          operands != [] -> [hd(operands).value]
          true -> []
        end

      cond do
        "-" in files and "--sandbox" not in seen -> opaque_from(command, args, :standard_input)
        nil in scripts -> opaque_from(command, args, :dynamic_script)
        Enum.any?(scripts, &sed_runs_commands?/1) -> opaque_from(command, args, :inline_code)
        true -> :plain
      end
    end)
  end

  # Reads a sed script far enough to find the `e` command and the `s///e`
  # flag. Anything it can't read counts as running a command.
  defp sed_runs_commands?(script) do
    sed_commands(script)
    false
  catch
    :sed_runs -> true
  end

  defp sed_runs, do: throw(:sed_runs)

  defp sed_commands(<<>>), do: :ok
  defp sed_commands(<<byte, rest::binary>>) when byte in [?\s, ?\t, ?\n, ?;, ?}], do: sed_commands(rest)
  defp sed_commands(<<?#, rest::binary>>), do: rest |> sed_line_rest() |> sed_commands()

  defp sed_commands(script) do
    script
    |> sed_address()
    |> sed_skip_blanks()
    |> case do
      <<?!, rest::binary>> -> sed_skip_blanks(rest)
      rest -> rest
    end
    |> sed_command()
  end

  defp sed_address(script) do
    case sed_one_address(script) do
      <<?,, rest::binary>> -> sed_one_address(rest)
      rest -> rest
    end
  end

  defp sed_one_address(<<byte, _rest::binary>> = script) when byte in ?0..?9 do
    rest = sed_skip_digits(script)

    case rest do
      <<?~, step::binary>> -> sed_skip_digits(step)
      rest -> rest
    end
  end

  defp sed_one_address(<<byte, rest::binary>>) when byte in [?+, ?~], do: sed_skip_digits(rest)
  defp sed_one_address(<<?$, rest::binary>>), do: rest
  defp sed_one_address(<<?/, rest::binary>>), do: rest |> sed_delimited(?/) |> sed_regex_flags()

  defp sed_one_address(<<?\\, delimiter, rest::binary>>) when delimiter != ?\n,
    do: rest |> sed_delimited(delimiter) |> sed_regex_flags()

  defp sed_one_address(script), do: script

  defp sed_regex_flags(<<flag, rest::binary>>) when flag in [?I, ?M], do: sed_regex_flags(rest)
  defp sed_regex_flags(rest), do: rest

  defp sed_command(<<>>), do: :ok
  defp sed_command(<<byte, rest::binary>>) when byte in [?{, ?}], do: sed_commands(rest)
  defp sed_command(<<?#, rest::binary>>), do: rest |> sed_line_rest() |> sed_commands()
  defp sed_command(<<byte, rest::binary>>) when byte in [?:, ?b, ?t, ?T, ?v], do: rest |> sed_label() |> sed_commands()
  defp sed_command(<<byte, rest::binary>>) when byte in [?a, ?i, ?c], do: rest |> sed_text() |> sed_commands()
  defp sed_command(<<byte, rest::binary>>) when byte in [?w, ?W, ?r, ?R], do: rest |> sed_line_rest() |> sed_commands()

  defp sed_command(<<byte, rest::binary>>) when byte in [?q, ?Q, ?l, ?L],
    do: rest |> sed_skip_blanks() |> sed_skip_digits() |> sed_commands()

  defp sed_command(<<byte, rest::binary>>) when byte in ~c"=dDgGhHnNpPxzF", do: sed_commands(rest)

  defp sed_command(<<?s, delimiter, rest::binary>>) when delimiter not in [?\n, ?\\],
    do: rest |> sed_delimited(delimiter) |> sed_delimited(delimiter) |> sed_s_flags()

  defp sed_command(<<?y, delimiter, rest::binary>>) when delimiter not in [?\n, ?\\],
    do: rest |> sed_delimited(delimiter) |> sed_delimited(delimiter) |> sed_commands()

  defp sed_command(_script), do: sed_runs()

  defp sed_s_flags(<<?e, _rest::binary>>), do: sed_runs()
  defp sed_s_flags(<<?w, rest::binary>>), do: rest |> sed_line_rest() |> sed_commands()
  defp sed_s_flags(<<flag, rest::binary>>) when flag in ~c"gpiImM0123456789", do: sed_s_flags(rest)
  defp sed_s_flags(<<byte, _rest::binary>> = rest) when byte in [?\s, ?\t, ?\n, ?;, ?}, ?#], do: sed_commands(rest)
  defp sed_s_flags(<<>>), do: :ok
  defp sed_s_flags(_rest), do: sed_runs()

  # Text up to an unescaped delimiter; an unterminated part counts as
  # running a command.
  defp sed_delimited(<<>>, _delimiter), do: sed_runs()
  defp sed_delimited(<<?\\, _escaped, rest::binary>>, delimiter), do: sed_delimited(rest, delimiter)
  defp sed_delimited(<<?\\>>, _delimiter), do: sed_runs()
  defp sed_delimited(<<delimiter, rest::binary>>, delimiter), do: rest
  defp sed_delimited(<<_byte, rest::binary>>, delimiter), do: sed_delimited(rest, delimiter)

  # `a`, `i` and `c` text runs to the end of the line, which a trailing
  # backslash continues.
  defp sed_text(<<>>), do: <<>>
  defp sed_text(<<?\\, _escaped, rest::binary>>), do: sed_text(rest)
  defp sed_text(<<?\n, rest::binary>>), do: rest
  defp sed_text(<<_byte, rest::binary>>), do: sed_text(rest)

  defp sed_label(script) do
    case :binary.match(script, [";", "\n"]) do
      {at, _size} -> binary_part(script, at, byte_size(script) - at)
      :nomatch -> <<>>
    end
  end

  defp sed_line_rest(script) do
    case :binary.match(script, "\n") do
      {at, 1} -> binary_part(script, at + 1, byte_size(script) - at - 1)
      :nomatch -> <<>>
    end
  end

  defp sed_skip_blanks(<<byte, rest::binary>>) when byte in [?\s, ?\t], do: sed_skip_blanks(rest)
  defp sed_skip_blanks(rest), do: rest

  defp sed_skip_digits(<<byte, rest::binary>>) when byte in ?0..?9, do: sed_skip_digits(rest)
  defp sed_skip_digits(rest), do: rest
end
