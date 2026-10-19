defmodule BeamWeaver.TextSplitter.Language do
  @moduledoc false

  alias BeamWeaver.TextSplitter.Shared

  # Most separators are a line starting with a keyword and a space, or with a
  # call, falling back to paragraphs, lines, words and characters.
  lines = fn keywords -> Enum.map(keywords, &"\n#{&1} ") end
  calls = fn names -> Enum.map(names, &"\n#{&1}\\(") end
  @tail ["\n\n", "\n", " ", ""]

  @c_separators lines.(~w(class void int float double if for while switch case)) ++ @tail
  @jsx_separators lines.(~w(function const export return)) ++ @tail

  @language_separators %{
    "c" => @c_separators,
    "cpp" => @c_separators,
    "go" => lines.(~w(func var const type if for switch case)) ++ @tail,
    "java" => lines.(~w(class public protected private static if for while switch case)) ++ @tail,
    "kotlin" =>
      lines.(~w(class public protected private internal companion fun val var if for while when else)) ++ @tail,
    "markdown" => ["\n\#{1,6} ", "```\n", "\n\\*\\*\\*+\n", "\n---+\n", "\n___+\n" | @tail],
    "html" =>
      Enum.map(
        ~w(body div p br li h1 h2 h3 h4 h5 h6 span table tr td th ul ol header footer nav head style script meta title),
        &"<#{&1}"
      ) ++ [""],
    "latex" =>
      Enum.map(~w(chapter section subsection subsubsection), &"\n\\\\#{&1}{") ++
        Enum.map(~w(enumerate itemize description list quote quotation verse verbatim align), &"\n\\\\begin{#{&1}}") ++
        ["$$", "$", " ", ""],
    "python" => ["\nclass ", "\ndef ", "\n\tdef " | @tail],
    "javascript" => lines.(~w(function const let var class if for while switch case default)) ++ @tail,
    "typescript" =>
      lines.(~w(enum interface namespace type class function const let var if for while switch case default)) ++ @tail,
    "jsx" => @jsx_separators,
    "tsx" => @jsx_separators,
    "php" => lines.(~w(function class if foreach while do switch case)) ++ @tail,
    "proto" => lines.(~w(message service enum option import syntax)) ++ @tail,
    "r" =>
      lines.(~w(function)) ++
        calls.(~w(setClass setMethod setGeneric)) ++
        lines.(~w(if else for while repeat)) ++ calls.(~w(library require)) ++ @tail,
    "rst" => ["\n=+\n", "\n-+\n", "\n\\*+\n", "\n\n.. *\n\n" | @tail],
    "ruby" => lines.(~w(def class if unless while for do begin rescue)) ++ @tail,
    "elixir" => lines.(~w(def defp defmodule defprotocol defmacro defmacrop if unless case cond with for do)) ++ @tail,
    "rust" => lines.(~w(fn const let if while for loop match)) ++ @tail,
    "scala" => lines.(~w(class object def val var if for while match case)) ++ @tail,
    "swift" => lines.(~w(func class struct enum if for while do switch case)) ++ @tail,
    "csharp" =>
      lines.(
        ~w(interface enum delegate event class abstract public protected private static return if continue for) ++
          ~w(foreach while switch break case else try throw finally catch)
      ) ++ @tail,
    "sol" =>
      lines.(
        ~w(pragma using contract interface library constructor type function event modifier error struct enum if) ++
          ~w(for while)
      ) ++ ["\ndo while ", "\nassembly " | @tail],
    "cobol" =>
      Enum.map(~w(IDENTIFICATION ENVIRONMENT DATA PROCEDURE), &"\n#{&1} DIVISION.") ++
        Enum.map(~w(WORKING-STORAGE LINKAGE FILE INPUT-OUTPUT), &"\n#{&1} SECTION.") ++
        lines.(~w(OPEN CLOSE READ WRITE IF ELSE MOVE PERFORM UNTIL VARYING ACCEPT DISPLAY)) ++
        ["\nSTOP RUN.", "\n", " ", ""],
    "lua" => lines.(~w(local function if for while repeat)) ++ @tail,
    "haskell" =>
      ["\nmain :: ", "\nmain = "] ++
        lines.(~w(let in do where :: = data newtype type module import qualified)) ++
        ["\nimport qualified "] ++ lines.(~w(class instance case |)) ++ ["\n= {", "\n, " | @tail],
    "powershell" => lines.(~w(function param if foreach for while switch class try catch finally)) ++ @tail,
    "visualbasic6" => [
      "\n(?!End\\s)(?:Public|Private|Friend|Global|Static)?\\s*Sub\\s+",
      "\n(?!End\\s)(?:Public|Private|Friend|Global|Static)?\\s*Function\\s+",
      "\n(?!End\\s)(?:Public|Private|Friend|Global|Static)?\\s*Property\\s+(?:Get|Let|Set)\\s+",
      "\n(?!End\\s)(?:Public|Private|Friend|Global|Static)?\\s*Type\\s+",
      "\n(?!End\\s)(?:Public|Private|Friend|Global|Static)?\\s*Enum\\s+",
      "\n(?!End\\s)If\\s+",
      "\nElseIf\\s+",
      "\nElse\\s+",
      "\nSelect\\s+Case\\s+",
      "\nCase\\s+",
      "\nFor\\s+",
      "\nDo\\s+",
      "\nWhile\\s+",
      "\nWith\\s+" | @tail
    ]
  }

  def separators(language) do
    Map.get(@language_separators, normalize(language), Shared.common_fields()[:separators])
  end

  defp normalize(language) when is_atom(language),
    do: language |> Atom.to_string() |> normalize()

  defp normalize(language) when is_binary(language) do
    language
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> case do
      "py" -> "python"
      "js" -> "javascript"
      "ts" -> "typescript"
      "md" -> "markdown"
      "ex" -> "elixir"
      "exs" -> "elixir"
      "golang" -> "go"
      "c_plus_plus" -> "cpp"
      "c_sharp" -> "csharp"
      "solidity" -> "sol"
      "vb6" -> "visualbasic6"
      "visual_basic_6" -> "visualbasic6"
      "vue" -> "jsx"
      "svelte" -> "jsx"
      other -> other
    end
  end

  defp normalize(_language), do: ""
end
