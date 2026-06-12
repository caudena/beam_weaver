defmodule BeamWeaver.TestSupport.Conformance.EmbeddingModelCase do
  @moduledoc """
  Shared ExUnit checks for `BeamWeaver.Core.EmbeddingModel` implementations.
  """

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use ExUnit.Case, async: true

      alias BeamWeaver.Core.Async
      alias BeamWeaver.Core.EmbeddingModel
      alias BeamWeaver.TestSupport.Conformance.Subject

      @beamweaver_subject Subject.new(opts, :embedding_model)

      test "embedding model returns one numeric vector per document" do
        model = build_subject()
        documents = fixture(:documents)

        assert {:ok, vectors} = EmbeddingModel.embed_documents(model, documents)
        assert length(vectors) == length(documents)
        assert Enum.all?(vectors, &(is_list(&1) and &1 != []))
        assert Enum.all?(List.flatten(vectors), &is_number/1)
      end

      test "embedding query returns the same vector dimension as documents" do
        model = build_subject()

        assert {:ok, [first_document_vector | _rest]} =
                 EmbeddingModel.embed_documents(model, [hd(fixture(:documents))])

        assert {:ok, query_vector} = EmbeddingModel.embed_query(model, fixture(:query))
        assert length(query_vector) == length(first_document_vector)

        if fixture(:dimensions) do
          assert length(query_vector) == fixture(:dimensions)
        end
      end

      test "embedding model rejects non-string document input before provider code runs" do
        model = build_subject()

        assert {:error, error} = EmbeddingModel.embed_documents(model, ["ok", :not_a_string])
        assert error.type == :invalid_documents
      end

      test "embedding model rejects non-string query input before provider code runs" do
        model = build_subject()

        assert {:error, error} = EmbeddingModel.embed_query(model, {:not, :a, :query})
        assert error.type == :invalid_query
      end

      test "embedding model async API returns document and query vectors" do
        model = build_subject()

        assert {:ok, vectors} =
                 model
                 |> EmbeddingModel.async_embed_documents(fixture(:documents))
                 |> Async.await()

        assert length(vectors) == length(fixture(:documents))

        assert {:ok, query_vector} =
                 model
                 |> EmbeddingModel.async_embed_query(fixture(:query))
                 |> Async.await()

        assert is_list(query_vector)
      end

      if Subject.capability?(@beamweaver_subject, :batch) do
        test "embedding model async batch preserves query order" do
          model = build_subject()

          handles = EmbeddingModel.async_batch_queries(model, ["first", "second"])
          assert [{:ok, first}, {:ok, second}] = Async.await_batch(handles)
          assert is_list(first)
          assert is_list(second)
          refute first == second
        end
      end

      if Subject.capability?(@beamweaver_subject, :deterministic) do
        test "embedding model returns deterministic vectors for repeated inputs" do
          model = build_subject()

          assert {:ok, first} = EmbeddingModel.embed_query(model, fixture(:query))
          assert {:ok, second} = EmbeddingModel.embed_query(model, fixture(:query))
          assert first == second
        end
      end

      if Subject.capability?(@beamweaver_subject, :standard_params) do
        test "embedding model accepts declared standard params and forwards them to provider boundary" do
          model = build_subject()
          opts = fixture(:standard_param_opts, dimensions: fixture(:dimensions, 3))

          assert {:ok, vectors} = EmbeddingModel.embed_documents(model, fixture(:documents), opts)
          assert length(vectors) == length(fixture(:documents))

          if fixture(:assert_forwarded_opts?, false) do
            assert_received {:fake_embedding_documents, _documents, forwarded_opts}

            for {key, value} <- opts do
              assert Keyword.get(forwarded_opts, key) == value
            end
          end
        end
      end

      if Subject.capability?(@beamweaver_subject, :env_config_init) do
        test "embedding model can be initialized from explicit env/config helper when supported" do
          {group, key, config_value} =
            fixture(:config, {:test_support, :fake_embedding_dimensions, "5"})

          BeamWeaver.TestSupport.ConfigHelper.merge_config(group, [{key, config_value}])

          model = fixture(:env_builder).()

          assert {:ok, vector} = EmbeddingModel.embed_query(model, fixture(:query))
          assert length(vector) == String.to_integer(config_value)
        end
      end

      if Subject.capability?(@beamweaver_subject, :param_validation) do
        test "embedding model validates unsupported params before transport/provider code" do
          model = build_subject()

          assert {:error, error} =
                   EmbeddingModel.embed_documents(model, fixture(:documents), dimensions: 42)

          assert error.type == :unsupported_model_param
        end
      end

      defp build_subject, do: Subject.build(@beamweaver_subject)
      defp fixture(key, default \\ nil), do: Subject.fixture(@beamweaver_subject, key, default)
    end
  end
end
