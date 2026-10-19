defmodule BeamWeaver.FormatterTest do
  use ExUnit.Case, async: true

  test "consumer formatting keeps DSL calls without parentheses" do
    {formatter, _} = Code.eval_file(Path.expand("../.formatter.exs", __DIR__))
    source = "defmodule Sample do\nuse BeamWeaver.Agent\nmodel \"fake:chat\"\ntools do\ntool MyTool\nend\nend"
    formatted = source |> Code.format_string!(formatter[:export]) |> IO.iodata_to_binary()

    assert formatted ==
             "defmodule Sample do\n  use BeamWeaver.Agent\n  model \"fake:chat\"\n\n  tools do\n    tool MyTool\n  end\nend"
  end
end
