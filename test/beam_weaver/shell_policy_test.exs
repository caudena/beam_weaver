defmodule BeamWeaver.ShellPolicyTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.ShellPolicy
  alias BeamWeaver.Tools.Shell

  # The commands of a list the policy allows, and the ones it refuses: a
  # failing assertion names exactly the commands that slipped through (or
  # were wrongly refused). `danger` and `fetch` stand for the programs the
  # deny rules keep out; nothing in the suite runs them.
  defp allowed(policy, commands), do: Enum.filter(commands, &ShellPolicy.allowed?(policy, &1))
  defp refused(policy, commands), do: Enum.reject(commands, &ShellPolicy.allowed?(policy, &1))

  defp reason(policy, command) do
    assert {:error, %Error{type: :shell_command_rejected, message: message}} = ShellPolicy.check(policy, command)
    message
  end

  # Allows any command line, as a policy that relies on deny rules does.
  defp deny_policy(opts \\ []) do
    ShellPolicy.new!([allow: [~r/.*/], allow_compound: true, deny: ["danger ", ~r/\Afetch /]] ++ opts)
  end

  describe "deny rules see the commands a wrapper runs" do
    test "through shells, eval and every prefix wrapper" do
      commands = [
        "sh -c 'danger now'",
        "bash -c 'danger now'",
        "dash -c \"danger now\"",
        "/bin/sh -c 'danger now'",
        "bash -lc 'danger now'",
        "bash -e -o pipefail -c 'danger now'",
        "sh -c 'echo ok; danger now'",
        "sh -c \"sh -c 'danger now'\"",
        "busybox sh -c 'danger now'",
        "eval 'danger now'",
        "eval danger now",
        "builtin eval 'danger now'",
        "trap 'danger now' EXIT",
        "alias ls='danger now'",
        "env danger now",
        "env -i danger now",
        "env -i HOME=/tmp danger now",
        "env -u FOO -- danger now",
        "/usr/bin/env danger now",
        "command danger now",
        "command -p danger now",
        "exec danger now",
        "exec -a name danger now",
        "nohup danger now",
        "time danger now",
        "time -p danger now",
        "nice danger now",
        "nice -n 5 danger now",
        "nice -5 danger now",
        "timeout 5 danger now",
        "timeout -k 1 -s KILL 5 danger now",
        "timeout --signal=KILL 5s danger now",
        "stdbuf -o0 -e0 danger now",
        "setsid -f danger now",
        "sudo danger now",
        "sudo -u root -E -- danger now",
        "doas danger now",
        "flock /tmp/lock danger now",
        "flock -n /tmp/lock -c 'danger now'",
        "chrt -f 10 danger now",
        "ionice -c 3 danger now",
        "taskset -c 0 danger now",
        "busybox danger now",
        "nice timeout 5 env sh -c 'danger now'"
      ]

      assert allowed(deny_policy(), commands) == []
    end

    test "through commands that run another per input, remotely or in an environment" do
      commands = [
        "xargs danger < files",
        "xargs -0 -n 1 danger < files",
        ~S(find . -exec danger {} \;),
        ~S(find . -name '*.o' -execdir danger {} +),
        ~S(find . -ok danger {} \;),
        "parallel danger ::: a b",
        "watch danger",
        "watch -n 1 'danger now'",
        "watch -x danger now",
        "script -q -c 'danger now' /dev/null",
        "ssh host danger now",
        "ssh -p 22 host 'danger now'",
        "poetry run danger now",
        "uv run danger now",
        "bundle exec danger now",
        "npm exec -- danger now"
      ]

      assert allowed(deny_policy(), commands) == []
    end

    test "through assignments, quoting, paths and other spellings of the command" do
      commands = [
        "FOO=1 danger x",
        "HTTP_PROXY=x fetch https://evil.test",
        "env fetch https://evil.test",
        "sh -c 'fetch https://evil.test'",
        ~S(\danger x),
        "d''anger x",
        "\"danger\" x",
        "/bin/danger x",
        "echo $(danger x)",
        "echo \"$(true; danger x)\"",
        "echo `danger x`",
        ~S<echo "`echo \`danger x\``>,
        "function f { danger x; }; f",
        "f() { danger x; }; f",
        "danger;x",
        "danger>/dev/null",
        "cat <(danger x)",
        "cat <<EOF\n$(danger x)\nEOF",
        "echo hi # it's\ndanger x #'"
      ]

      assert allowed(deny_policy(), commands) == []
    end

    test "even when allow_opaque lets ordinary rules allow code the policy can't read" do
      policy = deny_policy(allow_opaque: true)

      # An empty expansion vanishes, and bash decodes `$'...'` escapes.
      assert allowed(policy, [
               "$UNSET danger x",
               "${UNSET}danger x",
               ~S<$'\x64\x61\x6e\x67\x65\x72' x>,
               "sh -c 'danger x'"
             ]) == []

      assert ShellPolicy.allowed?(policy, "sh -c \"$SCRIPT\"")
    end

    test "leave a here-document's quoted body alone" do
      policy = deny_policy()

      assert ShellPolicy.allowed?(policy, "cat > notes.md <<'EOF'\ndanger is a placeholder here\nEOF")
      assert ShellPolicy.allowed?(policy, "cat <<EOF\ndanger is $HOME\nEOF")
      refute ShellPolicy.allowed?(policy, "cat <<EOF\n$(danger x)\nEOF")
    end
  end

  describe "allow rules apply to the command a wrapper runs" do
    test "allowing a wrapper allows nothing it wraps" do
      policy =
        ShellPolicy.new!(
          allow:
            ~w(sh bash env timeout nice nohup command exec time stdbuf busybox flock eval trap) ++
              ~w(sudo xargs find ssh watch setsid script parallel poetry)
        )

      commands = [
        "sh -c 'touch x'",
        "bash -c \"touch x\"",
        "env touch x",
        "timeout 5 touch x",
        "nice touch x",
        "nohup touch x",
        "command touch x",
        "exec touch x",
        "time touch x",
        "stdbuf -oL touch x",
        "busybox touch x",
        "flock /tmp/l touch x",
        "eval touch x",
        "trap 'touch x' EXIT",
        "sudo touch x",
        "xargs touch < files",
        ~S(find . -exec touch {} \;),
        "ssh host touch x",
        "watch touch x",
        "setsid touch x",
        "script -c 'touch x'",
        "parallel touch ::: a",
        "poetry run touch x"
      ]

      assert allowed(policy, commands) == []
    end

    test "a wrapped command that is allowed runs through a wrapper that needs no rule" do
      policy = ShellPolicy.new!(allow: ["pytest", "make", "git status", "ls"])

      commands = [
        "timeout 30 pytest -q",
        "env FOO=1 make",
        "env -i CI=1 make test",
        "FOO=1 make",
        "nice -n 5 make",
        "nohup make",
        "time make",
        "command make",
        "exec make",
        "stdbuf -oL make",
        "timeout 5 nice -n 2 pytest",
        "sh -c 'make test'",
        "bash -c \"pytest -q\"",
        "eval 'make test'",
        "  ls -la # list the files"
      ]

      assert refused(policy, commands) == []

      assert allowed(policy, [
               "timeout 30 danger now",
               "env touch x",
               "sh -c 'make; touch x'",
               "sudo make",
               "xargs ls < dirs",
               "timeout",
               "env"
             ]) == []

      assert reason(policy, "timeout 30 danger now") =~ "no allow rule matches `danger now`"
    end

    test "a command that runs another for its user, host or input needs a rule of its own too" do
      policy = ShellPolicy.new!(allow: ~w(sudo find xargs ssh apt-get grep))

      assert refused(policy, [
               "sudo apt-get update",
               "sudo timeout 5 apt-get update",
               "find . -name '*.log' -exec grep -l error {} +",
               "xargs grep -l error < files",
               "ssh build-host grep -r TODO src"
             ]) == []

      assert allowed(policy, ["sudo ls", ~S(find . -exec ls {} \;), "ssh host ls", "xargs ls < dirs"]) == []
    end

    test "a rule that spells out the wrapped command allows it" do
      policy = ShellPolicy.new!(allow: ["sudo apt-get update", "timeout 30 pytest"])

      assert refused(policy, ["sudo apt-get update", "timeout 30 pytest -q"]) == []
      assert allowed(policy, ["sudo apt-get install curl", "timeout 30 danger now", "sudo -s"]) == []
    end
  end

  describe "code the policy can't read" do
    @programs ~w(python3 perl ruby node php lua awk sed vim git tar make bash sh zsh eval source xargs strace gdb)

    @opaque_commands [
      "python3 -c 'print(1)'",
      "python3 -",
      "python3",
      "perl -e 'print 1'",
      "perl -lane 'print $F[0]'",
      "perl -de 0",
      "perl -MPOSIX script.pl",
      "ruby -e 'puts 1'",
      "ruby -Kue 'puts 1'",
      "node -e 'console.log(1)'",
      "node --eval=1",
      "node",
      "php -r 'echo 1;'",
      "lua -e 'print(1)'",
      "awk 'BEGIN { system(\"id\") }'",
      "awk '{ print | \"sh\" }' log",
      "awk -f - log",
      "sed 's/a/b/e' file",
      "sed '1e id' file",
      "sed -f - file",
      "vim -c ':!id' file",
      "vim +':!id' file",
      "git -c core.sshCommand=id fetch",
      "git -c alias.x='!id' x",
      "git rebase -x id HEAD~1",
      "git submodule foreach id",
      "tar --to-command=id -xf a.tar",
      "tar -I id -xf a.tar",
      "make --eval 'all:'",
      "make -f - all",
      "bash build.sh",
      "sh",
      "bash -s",
      "bash -i",
      "source env.sh",
      "sh -c \"$SCRIPT\"",
      "eval \"$CMD\"",
      "$TOOL --version",
      "\"$TOOL\" --version",
      "xargs sh -c 'id'",
      "xargs -I{} sh -c 'echo {}'",
      "zsh -c 'id'",
      "strace ls",
      "gdb -batch -ex 'shell id'"
    ]

    # Commands whose name is only known at run time.
    @dynamic_names [
      "$TOOL --version",
      "\"$TOOL\" --version",
      "{danger,x}",
      "/bin/d? x",
      ~S<$'\x64\x61\x6e\x67\x65\x72' x>
    ]

    test "is refused even when a rule allows the program" do
      policy = ShellPolicy.new!(allow: @programs)

      assert allowed(policy, @opaque_commands ++ @dynamic_names) == []
      assert reason(policy, "python3 -c 'print(1)'") =~ "can't read (inline code)"
      assert reason(policy, "sh -c \"$SCRIPT\"") =~ "can't read (dynamic script)"
      assert reason(policy, "bash build.sh") =~ "can't read (script file)"
    end

    test "while what the policy can read still runs" do
      policy = ShellPolicy.new!(allow: @programs)

      assert refused(policy, [
               "python3 script.py",
               "python3 -m pytest -q",
               "perl script.pl",
               "node app.js",
               "awk -F, '{ print $1 }' data.csv",
               "sed -n '1,5p' file",
               "sed -i 's/foo/bar/g' file",
               "git status",
               "tar -xzf a.tgz",
               "make test",
               "bash -c 'make test'"
             ]) == []
    end

    test "is allowed by a rule that spells out the part the policy can't read" do
      policy = ShellPolicy.new!(allow: ["python3 -c", "bash scripts/ci.sh", "sh -c"])

      assert refused(policy, [
               "python3 -c 'print(1)'",
               "bash scripts/ci.sh",
               "sh -c \"$SCRIPT\""
             ]) == []

      assert allowed(policy, ["python3 script.py", "bash scripts/other.sh", "python3 -cx 'print(1)'"]) == []
    end

    test "is allowed by ordinary rules with allow_opaque" do
      policy = ShellPolicy.new!(allow: @programs, allow_opaque: true, deny: ["danger "])

      # Inline code, scripts and dynamic arguments the program rules name are
      # now allowed.
      assert refused(policy, @opaque_commands -- @dynamic_names) == []

      # A deny rule still catches a command inside a readable wrapper, and a
      # command no rule names stays refused even with allow_opaque.
      assert allowed(policy, ["sh -c 'danger x'", "cp a b" | @dynamic_names]) == []

      assert {:error, %Error{message: "allow_opaque must be a boolean"}} =
               ShellPolicy.new(allow: ["ls"], allow_opaque: "yes")
    end
  end

  describe "variable assignments" do
    test "are allowed with plain values for variables that don't run code" do
      policy = ShellPolicy.new!(allow: ["make", "export"])

      assert refused(policy, [
               "FOO=1 make",
               "CI=true RUST_LOG=debug make test",
               "DATABASE_URL=postgres://u@db:5432/app make",
               "env FOO=1 make",
               "export NODE_ENV=production"
             ]) == []
    end

    test "are refused for variables that load or run code, and for values with shell syntax" do
      policy = ShellPolicy.new!(allow: ["make", "export", "ls"])

      assert allowed(policy, [
               "PATH=/tmp/evil:/usr/bin ls",
               "LD_PRELOAD=/tmp/x.so make",
               "DYLD_INSERT_LIBRARIES=/tmp/x.dylib make",
               "BASH_ENV=/tmp/x make",
               "GIT_SSH_COMMAND=id make",
               "PAGER=id make",
               "CC=gcc make",
               "env PATH=/tmp/evil make",
               "FOO='a b' make",
               "FOO='$(id)' make",
               "FOO=$BAR make",
               "export PATH=/tmp/evil",
               "export x='a[$(id)]'"
             ]) == []
    end

    test "before a command may hold glob characters, which the shell doesn't expand there" do
      policy = ShellPolicy.new!(allow: ["npm test", "make", "export"])

      assert refused(policy, [
               "DEBUG=* npm test",
               "DEBUG=express:* LOG_LEVEL=debug? make",
               "CONFIG=conf/[ab].json make",
               "PATTERN=[ make",
               "2>/dev/null DEBUG=* npm test",
               "sh -c 'DEBUG=* npm test'",
               # Quoted, they are plain text anywhere.
               "env 'DEBUG=*' make",
               "export 'DEBUG=a?b' CONFIG='[ab].json'"
             ]) == []

      # On their own, and among other commands, the line still needs a rule
      # that allows it.
      assert refused(deny_policy(), [
               "DEBUG=*",
               "DEBUG=*; npm test",
               "if DEBUG=* make; then echo ok; fi",
               "echo \"$(DEBUG=a?b make)\""
             ]) == []

      # Deny rules still see the command after them.
      assert allowed(deny_policy(), ["DEBUG=* danger x", "sh -c 'DEBUG=[ab] danger x'"]) == []
    end

    test "with glob characters are refused where the shell expands them" do
      policy = ShellPolicy.new!(allow: ["make", "export", "readonly", "sudo make", "eval"])

      # As arguments of `env`, `export`, `sudo`, `make`, `eval` or a wrapper the
      # shell expands them to file names, and dash reads `NAME+=` as a command
      # name. (bash, zsh, busybox and dash 0.5.11+ read `export NAME=*` as an
      # assignment, but older dash and POSIX before 2024 expand it.)
      refused = [
        "env DEBUG=* make",
        "export DEBUG=*",
        "readonly DEBUG=a?b",
        "sudo DEBUG=* make",
        "make DEBUG=*",
        "eval DEBUG=* make",
        "timeout 5 DEBUG=* make",
        "time DEBUG=* make",
        "nice DEBUG=[ab] make",
        "DEBUG+=* make"
      ]

      # Other expansions, values with other shell syntax, and the variables
      # that run code stay refused too.
      refused =
        refused ++
          [
            "DEBUG=$HOME/* make",
            "DEBUG=$(id)* make",
            "DEBUG=$((1+2))* make",
            "DEBUG={a,b} make",
            "DEBUG='a b*' make",
            "PATH=* make",
            "LD_PRELOAD=/tmp/* make",
            "a[0]=* make"
          ]

      assert allowed(policy, refused) == []
      assert allowed(deny_policy(), refused) == []
      assert reason(deny_policy(), "env DEBUG=* make") =~ "can't read (dynamic option)"
      assert reason(deny_policy(), "export DEBUG=*") =~ "can't read (dynamic assignment)"
      assert reason(deny_policy(), "PATH=* make") =~ "can't read (dangerous variable)"
      assert reason(deny_policy(), "DEBUG={a,b} make") =~ "can't read (assignment value)"
    end
  end

  describe "an assignment before a command, compared with the real shells" do
    alias BeamWeaver.ShellPolicy.Parser

    # Files the patterns below would match if a shell expanded them.
    setup do
      dir = Path.join(System.tmp_dir!(), "beam_weaver_assignment_globs_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      for name <- ["DEBUG=globbed", "LOG=globbed", "a1", "aXb", "x"], do: File.write!(Path.join(dir, name), "")

      shells = for name <- ~w(sh dash bash ksh mksh yash posh), path = System.find_executable(name), do: path
      assert System.find_executable("sh") in shells

      %{dir: dir, shells: shells}
    end

    # What each shell assigns, run in `dir`.
    defp assigned(shells, dir, line) do
      Map.new(shells, fn shell ->
        {output, _status} = System.cmd(shell, ["-c", line], cd: dir, stderr_to_stdout: true)
        {shell, String.trim_trailing(output, "\n")}
      end)
    end

    test "every shell assigns the value the policy reads", %{dir: dir, shells: shells} do
      lines = [
        {"DEBUG=* printenv DEBUG", "DEBUG=*"},
        {"DEBUG=a?b printenv DEBUG", "DEBUG=a?b"},
        {"DEBUG=a[0-9] printenv DEBUG", "DEBUG=a[0-9]"},
        {"DEBUG=[ printenv DEBUG", "DEBUG=["},
        {"DEBUG=x* LOG=* printenv LOG", "LOG=*"},
        {"2>/dev/null DEBUG=* printenv DEBUG", "DEBUG=*"},
        {"DEBUG=*; printf '%s\\n' \"$DEBUG\"", "DEBUG=*"}
      ]

      for {line, assignment} <- lines do
        assert ShellPolicy.allowed?(deny_policy(), line), line

        {:ok, %{commands: [%{words: words} | _more]}} = Parser.parse(line)
        assert assignment in Enum.map(words, & &1.value), line

        [_name, value] = String.split(assignment, "=", parts: 2)
        assert assigned(shells, dir, line) == Map.new(shells, &{&1, value}), line
      end
    end

    test "the shells expand the same text given to env, which the policy refuses", %{dir: dir, shells: shells} do
      line = "env DEBUG=* printenv DEBUG"

      refute ShellPolicy.allowed?(deny_policy(), line)
      assert assigned(shells, dir, line) == Map.new(shells, &{&1, "globbed"})
    end
  end

  describe "bash arithmetic, which can run a command stored in a variable" do
    test "is refused when it reads a variable" do
      policy = deny_policy()

      assert allowed(policy, [
               "x='a[$(danger x)]'; echo $((x))",
               "echo $((x + 1))",
               "((i++))",
               "let x=1",
               "echo $[x]",
               "echo ${a[i]}",
               "echo ${s:i}",
               "echo ${!name}",
               "echo ${x@P}",
               "[[ $x -eq 1 ]]",
               "declare -i x=1",
               "printf -v 'a[$(danger x)]' x",
               "read 'a[$(danger x)]'",
               "test -v 'a[$(danger x)]'",
               "cat <<EOF\n$((x))\nEOF"
             ]) == []
    end

    test "is left alone on numbers" do
      assert refused(deny_policy(), [
               "echo $((1 + 2))",
               "echo ${a[0]} ${a[@]} ${#a[@]}",
               "echo ${x:-default} ${x:1:2} ${x: -1}",
               "[[ 1 -eq 1 ]]",
               "[[ -f x ]]"
             ]) == []
    end
  end

  describe "the command line scanner" do
    test "reads comments, quotes and here-documents the way the shell does" do
      policy = ShellPolicy.new!(allow: ["echo", "printf"], deny: ["danger "])

      # Each of these hid a second command from a scanner that only tracked
      # quoting shallowly: a quote in a comment, `$'\''` (one quote to bash,
      # a quote and more to dash), a command substitution in double quotes.
      assert allowed(policy, [
               "echo hi # it's\ndanger x #'",
               "echo hi # it's\ndanger x\n'",
               ~S<echo $'\''; danger x>,
               "echo \"$(true; danger x)\"",
               "printf 'unterminated"
             ]) == []

      assert refused(policy, ["echo hi # a comment; and more", "echo 'a # b; c'", "echo \"$HOME\" > out.txt"]) == []
    end

    test "refuses what it can't read the same way in every shell" do
      policy = deny_policy()

      assert reason(policy, ~S<echo $'\''; danger x>) =~ "can't be read reliably (ambiguous ansi c quote)"
      assert reason(policy, "echo ${x:-'a b'}") =~ "quote in parameter expansion"
      assert reason(policy, "echo $(case x in x) id;; esac)") =~ "case in substitution"
      assert reason(policy, "cat <<EOF\nno end") =~ "unterminated heredoc"
    end

    test "follows wrappers eight levels deep and no further" do
      policy = ShellPolicy.new!(allow: ["ls"])

      assert ShellPolicy.allowed?(policy, String.duplicate("nice ", 8) <> "ls")
      refute ShellPolicy.allowed?(policy, String.duplicate("nice ", 9) <> "ls")
      assert reason(policy, String.duplicate("eval ", 9) <> "ls") =~ "more than 8 levels deep"
    end
  end

  test "the shell tool runs what the policy reads and refuses the rest before running it" do
    dir = Path.join(System.tmp_dir!(), "beam_weaver_shell_wrappers_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    shell = Shell.new(policy: [allow: ["printf", "echo", "sh"], cwd: dir])

    assert {:ok, %{output: "ok"}} = Tool.invoke(shell, %{"command" => "sh -c 'printf ok'"})

    refused = ["sh -c 'touch marker'", "echo hi # it's\ntouch marker #'", "sh -c \"$(printf touch) marker\""]

    for command <- refused do
      assert {:error, %Error{type: :shell_command_rejected, message: message}} =
               Tool.invoke(shell, %{"command" => command})

      assert message =~ "shell command is not allowed: "
    end

    refute File.exists?(Path.join(dir, "marker"))
  end
end
