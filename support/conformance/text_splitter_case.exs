defmodule BeamWeaver.TestSupport.Conformance.TextSplitterCase do
  @moduledoc """
  Shared ExUnit checks for text splitters.
  """

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use ExUnit.Case, async: true

      alias BeamWeaver.Core.Document
      alias BeamWeaver.TextSplitter

      @beamweaver_splitter Keyword.fetch!(opts, :splitter)

      test "splitter returns document chunks with metadata" do
        splitter = beamweaver_standard_value(@beamweaver_splitter)
        document = Document.new!("one two three four five", metadata: %{source: "case"})

        assert {:ok, stream} = TextSplitter.split_documents(splitter, [document])
        chunks = Enum.to_list(stream)
        assert chunks != []
        assert Enum.all?(chunks, &(&1.metadata.source == "case"))
      end

      defp beamweaver_standard_value(value) when is_function(value, 0), do: value.()
      defp beamweaver_standard_value(value), do: value
    end
  end
end
