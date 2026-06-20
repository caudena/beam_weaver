defmodule BeamWeaver.TestSupport.Conformance.DocumentLoaderCase do
  @moduledoc """
  Shared ExUnit checks for document loaders.
  """

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use ExUnit.Case, async: true

      alias BeamWeaver.Core.Document
      alias BeamWeaver.DocumentLoader

      @beamweaver_loader Keyword.fetch!(opts, :loader)

      test "loader returns an enumerable of documents" do
        loader = beamweaver_standard_value(@beamweaver_loader)

        assert {:ok, stream} = DocumentLoader.load(loader)
        assert Enumerable.impl_for(stream)
        assert Enum.all?(Enum.to_list(stream), &match?(%Document{}, &1))
      end

      defp beamweaver_standard_value(value),
        do: BeamWeaver.TestSupport.Conformance.Subject.standard_value(value)
    end
  end
end
