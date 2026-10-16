defmodule BeamWeaver.ShellPolicy.Parser do
  @moduledoc false

  # Reads a shell command line far enough to list every simple command it can
  # run: the commands between `;`, `&`, `|`, newlines and parentheses, and the
  # ones inside `$(...)`, backticks, `<(...)`, `>(...)` and here-documents.
  # Each command comes with its words, after quote removal where nothing in a
  # word expands at run time.
  #
  # It follows the POSIX shell grammar as bash and dash read it. Where they
  # read a construct differently, or where reading it right would take a full
  # shell parser (quotes inside `${...}`, `case` inside `$(...)`, `$'\''`), it
  # returns an error, which the policy refuses. It never guesses in a
  # direction that would hide a command: a `\r` ends a command although the
  # shell reads it as part of a word, and so on.

  defmodule Word do
    @moduledoc false

    # `value` is the word after quote removal, or `nil` when part of it is
    # only known at run time (an expansion, a glob, a brace expansion);
    # `literal` is the same, but with globs and braces read as text, as an
    # assignment reads them. `approx` is the same text with each expansion
    # left as written, and `bare` the same text with expansions left out (as
    # an empty one is). Deny rules read both. `opaque` names a construct that
    # can run code the policy can't see, such as bash arithmetic on a
    # variable, which can run a command substitution stored in that variable.
    defstruct [:raw, :value, :literal, :approx, :start, :stop, bare: "", quoted?: false, opaque: nil]
  end

  defmodule Command do
    @moduledoc false

    # A simple command: its words (leading assignments included, redirections
    # left out) and where it sits in `source`. A command read from backtick
    # text has `in_line?: false`: its offsets point into that text.
    defstruct [:source, :start, :stop, words: [], in_line?: true]

    def text(%__MODULE__{source: source, start: start, stop: stop}),
      do: binary_part(source, start, stop - start)
  end

  defmodule Line do
    @moduledoc false

    # `single?` is true for a line that runs exactly one simple command: no
    # control operators, subshells, substitutions or NUL bytes.
    defstruct [:text, commands: [], single?: false]
  end

  # Words the shell reads as reserved at the start of a command; the command
  # they introduce follows them.
  @reserved ~w(! { if then else elif while until do)

  @metachars [?\s, ?\t, ?\n, ?\r, ?;, ?&, ?|, ?(, ?), ?<, ?>]
  @special_parameters ~c"@*#?-$!0123456789"
  @max_nesting 16

  @spec parse(binary()) :: {:ok, Line.t()} | {:error, atom()}
  def parse(text) when is_binary(text) do
    # A NUL byte can't reach the shell (it ends a C string), so each part of
    # the line around one is read on its own, from an unquoted start, and the
    # line counts as more than one command.
    pieces = nul_pieces(text)

    {commands, compound?} =
      Enum.reduce(pieces, {[], length(pieces) > 1}, fn {from, to}, {acc, compound?} ->
        {tokens, nested, _pos} = scan(text, from, to, :top, 0, true)
        commands = split(tokens, text, true)
        ops? = Enum.any?(tokens, &match?({:op, _start, _stop}, &1))
        {acc ++ commands ++ nested, compound? or ops? or nested != []}
      end)

    {:ok, %Line{text: text, commands: commands, single?: not compound? and match?([_], commands)}}
  catch
    {__MODULE__, reason} -> {:error, reason}
  end

  defp nul_pieces(text), do: nul_pieces(text, 0, :binary.matches(text, <<0>>), [])

  defp nul_pieces(text, from, [], acc), do: Enum.reverse([{from, byte_size(text)} | acc])

  defp nul_pieces(text, from, [{at, 1} | rest], acc),
    do: nul_pieces(text, at + 1, rest, [{from, at} | acc])

  defp fail(reason), do: throw({__MODULE__, reason})

  ## Tokens

  # Returns the tokens of a command list running from `pos` to `stop` (or, for
  # a `$(...)`, to its closing parenthesis), the commands nested inside them
  # and the position after the list.
  defp scan(_text, _pos, _stop, _ctx, depth, _in_line?) when depth > @max_nesting,
    do: fail(:nested_too_deeply)

  defp scan(text, pos, stop, ctx, depth, in_line?) do
    state = %{
      ctx: ctx,
      depth: depth,
      in_line?: in_line?,
      tokens: [],
      nested: [],
      parens: 0,
      heredocs: [],
      target?: false
    }

    loop(text, pos, stop, state)
  end

  defp loop(_text, pos, stop, state) when pos >= stop do
    cond do
      state.ctx == :subst -> fail(:unterminated_substitution)
      state.heredocs != [] -> fail(:unterminated_heredoc)
      true -> {Enum.reverse(state.tokens), state.nested, pos}
    end
  end

  defp loop(text, pos, stop, state) do
    case :binary.at(text, pos) do
      byte when byte in [?\s, ?\t] ->
        loop(text, pos + 1, stop, state)

      ?\\ ->
        if at(text, pos + 1, stop) == ?\n,
          do: loop(text, pos + 2, stop, state),
          else: word(text, pos, stop, state)

      ?# ->
        loop(text, skip_comment(text, pos, stop), stop, state)

      ?\n ->
        state = op(state, pos, pos + 1)
        {pos, state} = read_heredocs(text, pos + 1, stop, state)
        loop(text, pos, stop, state)

      ?\r ->
        loop(text, pos + 1, stop, op(state, pos, pos + 1))

      ?; ->
        size = operator_size(text, pos, stop, [";;&", ";;", ";&", ";"])
        loop(text, pos + size, stop, op(state, pos, pos + size))

      ?& ->
        size = operator_size(text, pos, stop, ["&&", "&"])
        loop(text, pos + size, stop, op(state, pos, pos + size))

      ?| ->
        size = operator_size(text, pos, stop, ["||", "|&", "|"])
        loop(text, pos + size, stop, op(state, pos, pos + size))

      ?( ->
        open_paren(text, pos, stop, state)

      ?) ->
        close_paren(text, pos, stop, state)

      byte when byte in [?<, ?>] ->
        angle(text, pos, pos, stop, state)

      byte when byte in ?0..?9 ->
        case skip_digits(text, pos, stop) do
          after_digits when after_digits < stop ->
            if :binary.at(text, after_digits) in [?<, ?>],
              do: angle(text, pos, after_digits, stop, state),
              else: word(text, pos, stop, state)

          _end ->
            word(text, pos, stop, state)
        end

      _byte ->
        word(text, pos, stop, state)
    end
  end

  defp op(state, start, stop),
    do: %{state | tokens: [{:op, start, stop} | state.tokens], target?: false}

  defp push(state, token), do: %{state | tokens: [token | state.tokens]}

  defp operator_size(text, pos, stop, operators) do
    operators
    |> Enum.find(&(pos + byte_size(&1) <= stop and binary_part(text, pos, byte_size(&1)) == &1))
    |> byte_size()
  end

  defp skip_digits(text, pos, stop) do
    if pos < stop and :binary.at(text, pos) in ?0..?9,
      do: skip_digits(text, pos + 1, stop),
      else: pos
  end

  # A comment runs to the end of the line; the newline itself is a token.
  defp skip_comment(text, pos, stop) do
    case :binary.match(text, "\n", scope: {pos, stop - pos}) do
      {newline, 1} -> newline
      :nomatch -> stop
    end
  end

  # `((` starts a bash arithmetic command when its text is arithmetic closed by
  # `))`; otherwise, as in bash, the parentheses are two subshells.
  defp open_paren(text, pos, stop, state) do
    with ?( <- at(text, pos + 1, stop),
         {:ok, after_arith, nested, variables?} <- arithmetic(text, pos + 2, stop, state.depth, state.in_line?) do
      raw = binary_part(text, pos, after_arith - pos)
      word = %Word{raw: raw, approx: raw, start: pos, stop: after_arith, opaque: variables? && :arithmetic}

      state
      |> push({:word, word})
      |> Map.update!(:nested, &(&1 ++ nested))
      |> then(&loop(text, after_arith, stop, &1))
    else
      _not_arithmetic ->
        state = %{op(state, pos, pos + 1) | parens: state.parens + 1}
        loop(text, pos + 1, stop, state)
    end
  end

  defp close_paren(_text, pos, _stop, %{ctx: :subst, parens: 0} = state) do
    if state.heredocs != [], do: fail(:unterminated_heredoc)
    {Enum.reverse(state.tokens), state.nested, pos + 1}
  end

  defp close_paren(text, pos, stop, state) do
    state = %{op(state, pos, pos + 1) | parens: max(state.parens - 1, 0)}
    loop(text, pos + 1, stop, state)
  end

  # A redirection (with an optional file descriptor before it, from `start`)
  # or a process substitution.
  defp angle(text, start, pos, stop, state) do
    byte = :binary.at(text, pos)
    next = at(text, pos + 1, stop)

    cond do
      next == ?( and start == pos ->
        {after_subst, commands} = substitution(text, pos + 2, stop, state.depth, state.in_line?)
        raw = binary_part(text, pos, after_subst - pos)
        word = %Word{raw: raw, approx: raw, start: pos, stop: after_subst}

        state
        |> push({:word, word})
        |> Map.update!(:nested, &(&1 ++ commands))
        |> then(&loop(text, after_subst, stop, &1))

      byte == ?< and next == ?< and at(text, pos + 2, stop) != ?< ->
        size = if at(text, pos + 2, stop) == ?-, do: 3, else: 2
        {delimiter, quoted?, after_delimiter} = heredoc_delimiter(text, pos + size, stop)
        heredoc = %{delimiter: delimiter, strip_tabs?: size == 3, quoted?: quoted?}

        state = push(state, {:redirect, start, after_delimiter})
        state = %{state | heredocs: state.heredocs ++ [heredoc], target?: false}
        loop(text, after_delimiter, stop, state)

      true ->
        size = redirect_size(byte, next, at(text, pos + 2, stop))
        state = %{push(state, {:redirect, start, pos + size}) | target?: true}
        loop(text, pos + size, stop, state)
    end
  end

  defp redirect_size(?<, ?<, ?<), do: 3
  defp redirect_size(?<, next, _third) when next in [?>, ?&], do: 2
  defp redirect_size(?>, next, _third) when next in [?>, ?&, ?|], do: 2
  defp redirect_size(_byte, _next, _third), do: 1

  defp word(text, pos, stop, state) do
    {word, nested, after_word} = scan_word(text, pos, stop, state.depth, state.in_line?)

    if state.ctx == :subst and word.raw == "case", do: fail(:case_in_substitution)

    kind =
      cond do
        state.target? -> :target
        named_descriptor?(word, text, after_word, stop) -> :target
        true -> :word
      end

    state = %{push(state, {kind, word}) | target?: false}
    loop(text, after_word, stop, %{state | nested: state.nested ++ nested})
  end

  # bash's `{fd}>file` allocates a descriptor into a variable: the word is part
  # of the redirection, not an argument.
  defp named_descriptor?(%Word{raw: raw}, text, after_word, stop),
    do: at(text, after_word, stop) in [?<, ?>] and Regex.match?(~r/\A\{[A-Za-z_][A-Za-z0-9_]*\}\z/, raw)

  ## Here-documents

  defp heredoc_delimiter(text, pos, stop) do
    pos = skip_blanks(text, pos, stop)
    {delimiter, quoted?, after_delimiter} = delimiter_word(text, pos, stop, [], false)
    if delimiter == "", do: fail(:invalid_heredoc_delimiter)
    {delimiter, quoted?, after_delimiter}
  end

  defp skip_blanks(text, pos, stop) do
    if pos < stop and :binary.at(text, pos) in [?\s, ?\t],
      do: skip_blanks(text, pos + 1, stop),
      else: pos
  end

  # The delimiter is the word with its quotes removed and nothing expanded; a
  # quote anywhere in it makes the body literal text.
  defp delimiter_word(_text, pos, stop, acc, quoted?) when pos >= stop,
    do: {IO.iodata_to_binary(acc), quoted?, pos}

  defp delimiter_word(text, pos, stop, acc, quoted?) do
    case :binary.at(text, pos) do
      byte when byte in @metachars ->
        {IO.iodata_to_binary(acc), quoted?, pos}

      ?\\ ->
        if pos + 1 >= stop, do: fail(:invalid_heredoc_delimiter)
        delimiter_word(text, pos + 2, stop, [acc, :binary.at(text, pos + 1)], true)

      ?' ->
        close = find_byte(text, ?', pos + 1, stop) || fail(:unterminated_single_quote)
        delimiter_word(text, close + 1, stop, [acc, binary_part(text, pos + 1, close - pos - 1)], true)

      ?" ->
        close = find_byte(text, ?", pos + 1, stop) || fail(:unterminated_double_quote)
        content = binary_part(text, pos + 1, close - pos - 1)
        if String.contains?(content, ["\\", "$", "`"]), do: fail(:invalid_heredoc_delimiter)
        delimiter_word(text, close + 1, stop, [acc, content], true)

      byte when byte in [?$, ?`] ->
        fail(:invalid_heredoc_delimiter)

      byte ->
        delimiter_word(text, pos + 1, stop, [acc, byte], quoted?)
    end
  end

  # The bodies of the pending here-documents start after a newline token, one
  # after another, each ending at a line that is exactly its delimiter. An
  # unquoted body runs its `$(...)` and backtick substitutions.
  defp read_heredocs(_text, pos, _stop, %{heredocs: []} = state), do: {pos, state}

  defp read_heredocs(text, pos, stop, state) do
    {pos, nested} =
      Enum.reduce(state.heredocs, {pos, []}, fn heredoc, {pos, nested} ->
        {body_stop, after_body} = heredoc_body(text, pos, stop, heredoc)

        if heredoc.quoted? do
          {after_body, nested}
        else
          {after_body, nested ++ heredoc_substitutions(text, pos, body_stop, state)}
        end
      end)

    {pos, %{state | heredocs: [], nested: state.nested ++ nested}}
  end

  # Returns where the body ends (the start of its delimiter line) and the
  # position after the delimiter line.
  defp heredoc_body(_text, pos, stop, _heredoc) when pos >= stop, do: fail(:unterminated_heredoc)

  defp heredoc_body(text, pos, stop, heredoc) do
    line_stop = find_byte(text, ?\n, pos, stop) || stop
    line = binary_part(text, pos, line_stop - pos)
    candidate = if heredoc.strip_tabs?, do: String.trim_leading(line, "\t"), else: line

    cond do
      candidate == heredoc.delimiter ->
        {pos, min(line_stop + 1, stop)}

      # Whether a line continued with a backslash can end the body differs
      # between shells; refuse rather than guess where the body ends.
      not heredoc.quoted? and String.ends_with?(line, "\\") ->
        fail(:heredoc_line_continuation)

      true ->
        heredoc_body(text, line_stop + 1, stop, heredoc)
    end
  end

  # The commands an unquoted body runs. An expansion in it that bash
  # evaluates as code (arithmetic on a variable, say) becomes a command of
  # its own holding just that expansion, so the policy sees it.
  defp heredoc_substitutions(text, pos, stop, state), do: heredoc_substitutions(text, pos, stop, state, [])

  defp heredoc_substitutions(_text, pos, stop, _state, acc) when pos >= stop, do: acc

  defp heredoc_substitutions(text, pos, stop, state, acc) do
    case :binary.at(text, pos) do
      ?\\ ->
        heredoc_substitutions(text, pos + 2, stop, state, acc)

      byte when byte in [?$, ?`] ->
        part = expansion(text, pos, stop, :double_quote, state.depth, state.in_line?)

        heredoc_substitutions(
          text,
          part.stop,
          stop,
          state,
          acc ++ part.nested ++ opaque_expansion(text, pos, part, state)
        )

      _byte ->
        heredoc_substitutions(text, pos + 1, stop, state, acc)
    end
  end

  defp opaque_expansion(_text, _pos, %{opaque: nil}, _state), do: []

  defp opaque_expansion(text, pos, part, state) do
    raw = binary_part(text, pos, part.stop - pos)
    word = %Word{raw: raw, approx: raw, start: pos, stop: part.stop, opaque: part.opaque}
    [%Command{source: text, start: pos, stop: part.stop, words: [word], in_line?: state.in_line?}]
  end

  ## Words

  defp scan_word(text, pos, stop, depth, in_line?) do
    acc = %{
      start: pos,
      value: [],
      approx: [],
      bare: [],
      dynamic?: false,
      quoted?: false,
      opaque: nil,
      nested: [],
      glob?: false,
      bracket?: false,
      brace: :none,
      depth: depth,
      in_line?: in_line?
    }

    word_loop(text, pos, stop, acc)
  end

  defp word_loop(text, pos, stop, acc) when pos >= stop, do: finish_word(text, pos, acc)

  defp word_loop(text, pos, stop, acc) do
    case :binary.at(text, pos) do
      byte when byte in @metachars ->
        finish_word(text, pos, acc)

      ?\\ ->
        case at(text, pos + 1, stop) do
          nil -> word_loop(text, pos + 1, stop, literal(acc, "\\"))
          ?\n -> word_loop(text, pos + 2, stop, acc)
          byte -> word_loop(text, pos + 2, stop, %{literal(acc, <<byte>>) | quoted?: true})
        end

      ?' ->
        close = find_byte(text, ?', pos + 1, stop) || fail(:unterminated_single_quote)
        content = binary_part(text, pos + 1, close - pos - 1)
        word_loop(text, close + 1, stop, %{literal(acc, content) | quoted?: true})

      ?" ->
        {after_quote, acc} = double_quoted(text, pos + 1, stop, acc)
        word_loop(text, after_quote, stop, %{acc | quoted?: true})

      byte when byte in [?$, ?`] ->
        part = expansion(text, pos, stop, :normal, acc.depth, acc.in_line?)
        word_loop(text, part.stop, stop, add_expansion(acc, text, pos, part))

      byte when byte in [?*, ??] ->
        word_loop(text, pos + 1, stop, %{literal(acc, <<byte>>) | glob?: true})

      ?[ ->
        word_loop(text, pos + 1, stop, %{literal(acc, "[") | bracket?: true})

      ?] ->
        word_loop(text, pos + 1, stop, %{literal(acc, "]") | glob?: acc.glob? or acc.bracket?})

      byte when byte in [?{, ?,, ?}, ?.] ->
        word_loop(text, pos + 1, stop, %{literal(acc, <<byte>>) | brace: brace(acc.brace, byte, text, pos, stop)})

      byte ->
        word_loop(text, pos + 1, stop, literal(acc, <<byte>>))
    end
  end

  # Tracks an unquoted `{`, then `,` or `..`, then `}`: a brace expansion in
  # bash, which turns one word into several.
  defp brace(:none, ?{, _text, _pos, _stop), do: :open
  defp brace(:open, ?,, _text, _pos, _stop), do: :separated

  defp brace(:open, ?., text, pos, stop),
    do: if(at(text, pos + 1, stop) == ?., do: :separated, else: :open)

  defp brace(:separated, ?}, _text, _pos, _stop), do: :expands
  defp brace(state, _byte, _text, _pos, _stop), do: state

  defp literal(acc, bytes), do: %{acc | value: [acc.value, bytes], approx: [acc.approx, bytes], bare: [acc.bare, bytes]}

  defp add_expansion(acc, text, pos, part) do
    %{
      acc
      | dynamic?: acc.dynamic? or part.dynamic?,
        value: [acc.value, part.value],
        approx: [acc.approx, part.approx || binary_part(text, pos, part.stop - pos)],
        bare: [acc.bare, part.approx || part.value],
        opaque: acc.opaque || part.opaque,
        nested: acc.nested ++ part.nested
    }
  end

  defp finish_word(text, pos, acc) do
    raw = binary_part(text, acc.start, pos - acc.start)
    literal = if acc.dynamic?, do: nil, else: IO.iodata_to_binary(acc.value)
    expands? = acc.glob? or acc.brace == :expands

    word = %Word{
      raw: raw,
      value: if(expands?, do: nil, else: literal),
      literal: literal,
      approx: IO.iodata_to_binary(acc.approx),
      bare: IO.iodata_to_binary(acc.bare),
      start: acc.start,
      stop: pos,
      quoted?: acc.quoted?,
      opaque: acc.opaque
    }

    {word, acc.nested, pos}
  end

  # The inside of a double-quoted string, from after its opening quote.
  defp double_quoted(_text, pos, stop, _acc) when pos >= stop, do: fail(:unterminated_double_quote)

  defp double_quoted(text, pos, stop, acc) do
    case :binary.at(text, pos) do
      ?" ->
        {pos + 1, acc}

      ?\\ ->
        case at(text, pos + 1, stop) do
          nil -> fail(:unterminated_double_quote)
          ?\n -> double_quoted(text, pos + 2, stop, acc)
          byte when byte in [?$, ?`, ?", ?\\] -> double_quoted(text, pos + 2, stop, literal(acc, <<byte>>))
          byte -> double_quoted(text, pos + 2, stop, literal(acc, <<?\\, byte>>))
        end

      byte when byte in [?$, ?`] ->
        part = expansion(text, pos, stop, :double_quote, acc.depth, acc.in_line?)
        double_quoted(text, part.stop, stop, add_expansion(acc, text, pos, part))

      byte ->
        double_quoted(text, pos + 1, stop, literal(acc, <<byte>>))
    end
  end

  ## Expansions

  # Reads the expansion or substitution starting with the `$` or backtick at
  # `pos`. `value` is its literal text when it turns out to expand to nothing
  # but itself (a lone `$`).
  defp expansion(text, pos, stop, mode, depth, in_line?) do
    case :binary.at(text, pos) do
      ?` -> backtick(text, pos, stop, mode, depth)
      ?$ -> dollar(text, pos, stop, mode, depth, in_line?)
    end
  end

  # `approx` is the text deny rules read for the part (its source text when
  # `nil`).
  defp part(stop, opts \\ []) do
    %{
      stop: stop,
      dynamic?: Keyword.get(opts, :dynamic?, true),
      value: Keyword.get(opts, :value, []),
      approx: Keyword.get(opts, :approx),
      opaque: Keyword.get(opts, :opaque),
      nested: Keyword.get(opts, :nested, [])
    }
  end

  defp dollar(text, pos, stop, mode, depth, in_line?) do
    case at(text, pos + 1, stop) do
      # bash's `$'...'` reads backslash escapes, so `$'\''` is one quote where
      # dash reads `$` and a quoted backslash. Refuse what they split apart.
      ?' when mode == :normal ->
        close = ansi_c(text, pos + 2, stop)
        part(close, approx: ansi_c_decode(binary_part(text, pos + 2, close - pos - 3)))

      ?" when mode == :normal ->
        {after_quote, acc} =
          double_quoted(text, pos + 2, stop, %{
            value: [],
            approx: [],
            bare: [],
            dynamic?: false,
            opaque: nil,
            nested: [],
            depth: depth,
            in_line?: in_line?
          })

        part(after_quote, opaque: acc.opaque, nested: acc.nested)

      ?( ->
        with ?( <- at(text, pos + 2, stop),
             {:ok, after_arith, nested, variables?} <- arithmetic(text, pos + 3, stop, depth, in_line?) do
          part(after_arith, opaque: variables? && :arithmetic, nested: nested)
        else
          _command_substitution ->
            {after_subst, commands} = substitution(text, pos + 2, stop, depth, in_line?)
            part(after_subst, nested: commands)
        end

      ?{ ->
        {after_param, opaque, nested} = parameter(text, pos + 2, stop, depth, in_line?)
        part(after_param, opaque: opaque, nested: nested)

      ?[ ->
        {after_arith, nested} = old_arithmetic(text, pos + 2, stop, depth, in_line?, 0, [])
        part(after_arith, opaque: :arithmetic, nested: nested)

      byte when byte in ?a..?z or byte in ?A..?Z or byte == ?_ ->
        part(skip_name(text, pos + 2, stop))

      byte when byte in @special_parameters ->
        part(pos + 2)

      _other ->
        part(pos + 1, dynamic?: false, value: "$")
    end
  end

  defp skip_name(text, pos, stop) do
    case at(text, pos, stop) do
      byte when byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or byte == ?_ -> skip_name(text, pos + 1, stop)
      _other -> pos
    end
  end

  defp ansi_c(_text, pos, stop) when pos >= stop, do: fail(:unterminated_single_quote)

  defp ansi_c(text, pos, stop) do
    case :binary.at(text, pos) do
      ?' -> pos + 1
      ?\\ -> if at(text, pos + 1, stop) == ?', do: fail(:ambiguous_ansi_c_quote), else: ansi_c(text, pos + 2, stop)
      _byte -> ansi_c(text, pos + 1, stop)
    end
  end

  # What bash makes of `$'...'` text, for deny rules to read: `$'\x72m'` is
  # `rm`. (dash reads it as `$` and a quoted string, which runs nothing a deny
  # rule could name.)
  @ansi_c_escapes %{?a => 7, ?b => 8, ?e => 27, ?E => 27, ?f => 12, ?n => 10, ?r => 13, ?t => 9, ?v => 11}

  defp ansi_c_decode(text), do: text |> ansi_c_decode([]) |> IO.iodata_to_binary()

  defp ansi_c_decode(<<?\\, ?x, rest::binary>>, acc), do: ansi_c_number(rest, ~r/\A[0-9a-fA-F]{1,2}/, 16, acc, "\\x")
  defp ansi_c_decode(<<?\\, ?u, rest::binary>>, acc), do: ansi_c_number(rest, ~r/\A[0-9a-fA-F]{1,4}/, 16, acc, "\\u")
  defp ansi_c_decode(<<?\\, ?U, rest::binary>>, acc), do: ansi_c_number(rest, ~r/\A[0-9a-fA-F]{1,8}/, 16, acc, "\\U")
  defp ansi_c_decode(<<?\\, ?c, char, rest::binary>>, acc), do: ansi_c_decode(rest, [acc, Bitwise.band(char, 31)])

  defp ansi_c_decode(<<?\\, digit, _::binary>> = text, acc) when digit in ?0..?7,
    do: ansi_c_number(binary_part(text, 1, byte_size(text) - 1), ~r/\A[0-7]{1,3}/, 8, acc, "\\")

  defp ansi_c_decode(<<?\\, char, rest::binary>>, acc) do
    case Map.fetch(@ansi_c_escapes, char) do
      {:ok, byte} -> ansi_c_decode(rest, [acc, byte])
      :error -> ansi_c_decode(rest, [acc, char])
    end
  end

  defp ansi_c_decode(<<byte, rest::binary>>, acc), do: ansi_c_decode(rest, [acc, byte])
  defp ansi_c_decode(<<>>, acc), do: acc

  defp ansi_c_number(text, pattern, base, acc, prefix) do
    case Regex.run(pattern, text) do
      [digits] ->
        code = String.to_integer(digits, base)
        rest = binary_part(text, byte_size(digits), byte_size(text) - byte_size(digits))
        char = if base == 8 or code < 128, do: <<rem(code, 256)>>, else: <<code::utf8>>
        ansi_c_decode(rest, [acc, char])

      nil ->
        ansi_c_decode(text, [acc, prefix])
    end
  rescue
    ArgumentError -> ansi_c_decode(text, [acc, prefix])
  end

  # A command substitution's commands, from after its `$(` (or `<(`) to the
  # position after its closing parenthesis.
  defp substitution(text, pos, stop, depth, in_line?) do
    {tokens, nested, after_subst} = scan(text, pos, stop, :subst, depth + 1, in_line?)
    {after_subst, split(tokens, text, in_line?) ++ nested}
  end

  # Backtick text is unescaped and read as a command line of its own.
  defp backtick(text, pos, stop, mode, depth) do
    close = closing_backtick(text, pos + 1, stop)
    content = unescape_backtick(binary_part(text, pos + 1, close - pos - 1), mode)

    if depth + 1 > @max_nesting, do: fail(:nested_too_deeply)
    {tokens, nested, _pos} = scan(content, 0, byte_size(content), :top, depth + 1, false)
    part(close + 1, nested: split(tokens, content, false) ++ nested)
  end

  defp closing_backtick(_text, pos, stop) when pos >= stop, do: fail(:unterminated_backtick)

  defp closing_backtick(text, pos, stop) do
    case :binary.at(text, pos) do
      ?` -> pos
      ?\\ -> closing_backtick(text, pos + 2, stop)
      _byte -> closing_backtick(text, pos + 1, stop)
    end
  end

  defp unescape_backtick(content, mode) do
    escapes = if mode == :double_quote, do: ~c"$`\\\"", else: ~c"$`\\"
    unescape_backtick(content, escapes, [])
  end

  defp unescape_backtick(<<?\\, byte, rest::binary>>, escapes, acc) do
    if byte in escapes,
      do: unescape_backtick(rest, escapes, [acc, byte]),
      else: unescape_backtick(rest, escapes, [acc, ?\\, byte])
  end

  defp unescape_backtick(<<byte, rest::binary>>, escapes, acc), do: unescape_backtick(rest, escapes, [acc, byte])
  defp unescape_backtick(<<>>, _escapes, acc), do: IO.iodata_to_binary(acc)

  # `${...}` from after its `${`. Quotes inside it are read differently by
  # bash and dash (and differently again inside double quotes), so they are
  # refused. Indirect expansion (`${!name}`), an array subscript that isn't a
  # number, `@` or `*`, a substring offset that names a variable
  # (`${x:i}`, bash arithmetic) and prompt expansion (`${x@P}`) make bash
  # evaluate a variable's value as code.
  defp parameter(text, pos, stop, depth, in_line?) do
    opaque =
      cond do
        at(text, pos, stop) == ?! -> :indirect_expansion
        substring_variable?(text, parameter_operator(text, pos, stop), stop) -> :arithmetic
        true -> nil
      end

    parameter(text, pos, stop, depth, in_line?, 0, opaque, [])
  end

  # Where the operator after a parameter's name (and subscript) starts.
  defp parameter_operator(text, pos, stop) do
    pos = if at(text, pos, stop) == ?#, do: pos + 1, else: pos

    pos =
      case at(text, pos, stop) do
        byte when byte in @special_parameters -> pos + 1
        _name -> skip_name(text, pos, stop)
      end

    if at(text, pos, stop) == ?[,
      do: (find_byte(text, ?], pos, stop) || stop) + 1,
      else: pos
  end

  # `${name:offset:length}`: the offset and length are bash arithmetic. (`:-`,
  # `:=`, `:?` and `:+` are other operators.)
  defp substring_variable?(text, pos, stop) do
    with ?: <- at(text, pos, stop),
         next when next not in [?-, ?=, ??, ?+] <- at(text, pos + 1, stop),
         close when is_integer(close) <- find_byte(text, ?}, pos, stop) do
      binary_part(text, pos + 1, close - pos - 1) =~ ~r/[A-Za-z_$`]/
    else
      _other -> false
    end
  end

  defp parameter(_text, pos, stop, _depth, _in_line?, _braces, _opaque, _nested) when pos >= stop,
    do: fail(:unterminated_parameter_expansion)

  defp parameter(text, pos, stop, depth, in_line?, braces, opaque, nested) do
    case :binary.at(text, pos) do
      ?} when braces == 0 ->
        {pos + 1, opaque, nested}

      ?} ->
        parameter(text, pos + 1, stop, depth, in_line?, braces - 1, opaque, nested)

      ?{ ->
        parameter(text, pos + 1, stop, depth, in_line?, braces + 1, opaque, nested)

      ?\\ ->
        parameter(text, pos + 2, stop, depth, in_line?, braces, opaque, nested)

      byte when byte in [?', ?"] ->
        fail(:quote_in_parameter_expansion)

      byte when byte in [?$, ?`] ->
        part = expansion(text, pos, stop, :double_quote, depth, in_line?)
        parameter(text, part.stop, stop, depth, in_line?, braces, opaque || part.opaque, nested ++ part.nested)

      ?[ ->
        {after_subscript, subscript_opaque, subscript_nested} = subscript(text, pos + 1, stop, depth, in_line?, pos + 1)

        parameter(
          text,
          after_subscript,
          stop,
          depth,
          in_line?,
          braces,
          opaque || subscript_opaque,
          nested ++ subscript_nested
        )

      ?@ ->
        opaque = if at(text, pos + 1, stop) == ?P, do: opaque || :prompt_expansion, else: opaque
        parameter(text, pos + 1, stop, depth, in_line?, braces, opaque, nested)

      _byte ->
        parameter(text, pos + 1, stop, depth, in_line?, braces, opaque, nested)
    end
  end

  defp subscript(_text, pos, stop, _depth, _in_line?, _from) when pos >= stop,
    do: fail(:unterminated_parameter_expansion)

  defp subscript(text, pos, stop, depth, in_line?, from) do
    case :binary.at(text, pos) do
      ?] ->
        content = binary_part(text, from, pos - from)
        opaque = if content in ["@", "*"] or Regex.match?(~r/\A[0-9]+\z/, content), do: nil, else: :array_subscript
        {pos + 1, opaque, []}

      byte when byte in [?', ?"] ->
        fail(:quote_in_parameter_expansion)

      byte when byte in [?$, ?`] ->
        part = expansion(text, pos, stop, :double_quote, depth, in_line?)
        {after_subscript, _opaque, nested} = subscript(text, part.stop, stop, depth, in_line?, from)
        {after_subscript, :array_subscript, part.nested ++ nested}

      _byte ->
        subscript(text, pos + 1, stop, depth, in_line?, from)
    end
  end

  # Arithmetic from after its `((`, up to the matching `))`. Returns `:fail`
  # when the text doesn't close that way, so the caller reads it as nested
  # subshells instead, as bash does. `variables?` is true when the expression
  # names a variable: bash evaluates a variable's value as arithmetic, which
  # runs any command substitution in an array subscript stored there.
  defp arithmetic(text, pos, stop, depth, in_line?),
    do: arithmetic(text, pos, stop, depth, in_line?, 0, false, [])

  defp arithmetic(_text, pos, stop, _depth, _in_line?, _parens, _variables?, _nested) when pos >= stop, do: :fail

  defp arithmetic(text, pos, stop, depth, in_line?, parens, variables?, nested) do
    case :binary.at(text, pos) do
      ?( ->
        arithmetic(text, pos + 1, stop, depth, in_line?, parens + 1, variables?, nested)

      ?) when parens > 0 ->
        arithmetic(text, pos + 1, stop, depth, in_line?, parens - 1, variables?, nested)

      ?) ->
        if at(text, pos + 1, stop) == ?), do: {:ok, pos + 2, nested, variables?}, else: :fail

      byte when byte in [?$, ?`] ->
        part = expansion(text, pos, stop, :double_quote, depth, in_line?)
        arithmetic(text, part.stop, stop, depth, in_line?, parens, true, nested ++ part.nested)

      byte when byte in [?', ?", ?\\] ->
        :fail

      byte when byte in ?a..?z or byte in ?A..?Z or byte == ?_ ->
        arithmetic(text, pos + 1, stop, depth, in_line?, parens, true, nested)

      _byte ->
        arithmetic(text, pos + 1, stop, depth, in_line?, parens, variables?, nested)
    end
  end

  # bash's old `$[...]` arithmetic.
  defp old_arithmetic(_text, pos, stop, _depth, _in_line?, _brackets, _nested) when pos >= stop,
    do: fail(:unterminated_arithmetic)

  defp old_arithmetic(text, pos, stop, depth, in_line?, brackets, nested) do
    case :binary.at(text, pos) do
      ?] when brackets == 0 ->
        {pos + 1, nested}

      ?] ->
        old_arithmetic(text, pos + 1, stop, depth, in_line?, brackets - 1, nested)

      ?[ ->
        old_arithmetic(text, pos + 1, stop, depth, in_line?, brackets + 1, nested)

      byte when byte in [?$, ?`] ->
        part = expansion(text, pos, stop, :double_quote, depth, in_line?)
        old_arithmetic(text, part.stop, stop, depth, in_line?, brackets, nested ++ part.nested)

      byte when byte in [?', ?", ?\\] ->
        fail(:unsupported_arithmetic)

      _byte ->
        old_arithmetic(text, pos + 1, stop, depth, in_line?, brackets, nested)
    end
  end

  ## Commands

  # Splits a token list into simple commands at its control operators,
  # dropping the reserved words that open a compound command (`if`, `then`,
  # `{`, `!`, ...) and the `function NAME` of a function definition, so each
  # command starts at the word the shell runs.
  defp split(tokens, source, in_line?) do
    tokens
    |> Enum.chunk_by(&match?({:op, _start, _stop}, &1))
    |> Enum.reject(&match?([{:op, _start, _stop} | _rest], &1))
    |> Enum.flat_map(fn chunk ->
      case chunk |> drop_reserved() |> command(source, in_line?) do
        nil -> []
        command -> [command]
      end
    end)
  end

  defp drop_reserved([{:word, %Word{raw: "function"}}, {:word, _name} | rest]), do: drop_reserved(rest)
  defp drop_reserved([{:word, %Word{raw: raw}} | rest]) when raw in @reserved, do: drop_reserved(rest)
  defp drop_reserved(tokens), do: tokens

  defp command([], _source, _in_line?), do: nil

  defp command(tokens, source, in_line?) do
    words = for {:word, word} <- tokens, do: word
    {start, _} = token_span(List.first(tokens))
    {_, stop} = token_span(List.last(tokens))
    %Command{source: source, start: start, stop: stop, words: assignment_values(words), in_line?: in_line?}
  end

  # The shell expands no glob or brace in an assignment before the command
  # name: `DEBUG=* make` sets DEBUG to `*` in every shell, so its value is
  # known. Only `NAME=` counts: dash reads bash's `NAME+=` and `NAME[i]=` as
  # a command name, and expands it. The arguments of `env`, `export` or a
  # wrapper are words like any other.
  defp assignment_values([%Word{raw: raw} = word | words]) do
    if Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*=/, raw),
      do: [%{word | value: word.literal} | assignment_values(words)],
      else: [word | words]
  end

  defp assignment_values([]), do: []

  defp token_span({kind, %Word{start: start, stop: stop}}) when kind in [:word, :target], do: {start, stop}
  defp token_span({:redirect, start, stop}), do: {start, stop}

  ## Helpers

  defp at(text, pos, stop) when pos < stop, do: :binary.at(text, pos)
  defp at(_text, _pos, _stop), do: nil

  defp find_byte(text, byte, pos, stop) do
    case :binary.match(text, <<byte>>, scope: {pos, max(stop - pos, 0)}) do
      {found, 1} -> found
      :nomatch -> nil
    end
  end
end
