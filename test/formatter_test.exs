defmodule BeamWeaver.FormatterTest do
  use ExUnit.Case, async: true

  # Words that only appear inside DSL blocks, such as `tools do tool ... end`.
  @block_words [
    tool: 1,
    tool: 2,
    subagent: 1,
    subagent: 2,
    async_subagent: 1,
    async_subagent: 2,
    include: 1,
    state: 1,
    channel: 1,
    channel: 2,
    join: 2,
    join: 3
  ]

  test ".formatter.exs exports every DSL call for no-parens style" do
    {formatter, _binding} = Code.eval_file(Path.expand("../.formatter.exs", __DIR__))
    exported = formatter[:export][:locals_without_parens]
    internal = [__using__: 1, __before_compile__: 1]

    dsl =
      BeamWeaver.Agent.DSL.imports() ++
        (BeamWeaver.Tool.__info__(:macros) -- internal) ++
        (BeamWeaver.Schema.__info__(:macros) -- internal) ++ @block_words

    assert Enum.uniq(dsl) -- exported == []
    assert formatter[:locals_without_parens] == exported
  end
end
