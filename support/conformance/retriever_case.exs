defmodule BeamWeaver.TestSupport.Conformance.RetrieverCase do
  @moduledoc """
  Shared ExUnit checks for retrievers.
  """

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use ExUnit.Case, async: true

      alias BeamWeaver.Core.Document
      alias BeamWeaver.Retriever

      @beamweaver_retriever Keyword.fetch!(opts, :retriever)
      @beamweaver_query Keyword.get(opts, :query, "query")
      @beamweaver_k_query Keyword.get(opts, :k_query)

      test "retriever returns documents for a query" do
        retriever = beamweaver_standard_value(@beamweaver_retriever)

        assert {:ok, docs} = Retriever.retrieve(retriever, @beamweaver_query)
        assert is_list(docs)
        assert Enum.all?(docs, &match?(%Document{}, &1))
      end

      if @beamweaver_k_query do
        test "retriever honors native k override at the call boundary" do
          retriever = beamweaver_standard_value(@beamweaver_retriever)

          assert {:ok, [_one]} = Retriever.retrieve(retriever, @beamweaver_k_query)
          assert {:ok, [_one]} = Retriever.retrieve(retriever, @beamweaver_k_query, k: 1)
          assert {:ok, docs} = Retriever.retrieve(retriever, @beamweaver_k_query, k: 2)
          assert length(docs) == 2
          assert Enum.all?(docs, &match?(%Document{}, &1))
        end
      end

      defp beamweaver_standard_value(value) when is_function(value, 0), do: value.()
      defp beamweaver_standard_value(value), do: value
    end
  end
end
