defmodule BeamWeaver.OpenAI.EmbeddingModelTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.EmbeddingModel, as: CoreEmbeddingModel
  alias BeamWeaver.Models.Profile
  alias BeamWeaver.OpenAI.EmbeddingModel
  alias BeamWeaver.Tokenizer.Approximate

  test "embeds documents through replay and preserves OpenAI index ordering" do
    request_body = %{
      "model" => "text-embedding-3-small",
      "input" => ["alpha", "beta"],
      "dimensions" => 3
    }

    response_body = %{
      "data" => [
        %{"index" => 1, "embedding" => [0.4, 0.5, 0.6]},
        %{"index" => 0, "embedding" => [0.1, 0.2, 0.3]}
      ]
    }

    model = replay_model(write_gzip_cassette([{request_body, response_body}]))

    assert {:ok, vectors} =
             CoreEmbeddingModel.embed_documents(model, ["alpha", "beta"],
               model: "text-embedding-3-small",
               dimensions: 3
             )

    assert vectors == [[0.1, 0.2, 0.3], [0.4, 0.5, 0.6]]
  end

  test "embeds query through the single-input OpenAI request shape" do
    request_body = %{
      "model" => "text-embedding-3-small",
      "input" => "alpha"
    }

    response_body = %{
      "data" => [
        %{"index" => 0, "embedding" => [0.1, 0.2]}
      ]
    }

    model = replay_model(write_gzip_cassette([{request_body, response_body}]))

    assert {:ok, [0.1, 0.2]} = CoreEmbeddingModel.embed_query(model, "alpha")
  end

  test "async query embedding preserves runtime kwargs and replay request shape" do
    request_body = %{
      "model" => "text-embedding-3-small",
      "input" => "async alpha",
      "dimensions" => 2,
      "encoding_format" => "float"
    }

    response_body = %{
      "data" => [
        %{"index" => 0, "embedding" => [0.7, 0.8]}
      ]
    }

    model = replay_model(write_gzip_cassette([{request_body, response_body}]))

    task =
      EmbeddingModel.async_embed_query(model, "async alpha",
        model: "text-embedding-3-small",
        dimensions: 2,
        extra_body: %{encoding_format: "float"}
      )

    assert {:ok, [0.7, 0.8]} = Async.await(task)
  end

  test "chunks document embedding requests without exceeding caller chunk size" do
    interactions = [
      {
        %{"model" => "text-embedding-3-small", "input" => ["text1", "text2"]},
        %{
          "data" => [
            %{"index" => 0, "embedding" => [0.1]},
            %{"index" => 1, "embedding" => [0.2]}
          ]
        }
      },
      {
        %{"model" => "text-embedding-3-small", "input" => ["text3", "text4"]},
        %{
          "data" => [
            %{"index" => 0, "embedding" => [0.3]},
            %{"index" => 1, "embedding" => [0.4]}
          ]
        }
      }
    ]

    model = replay_model(write_gzip_cassette(interactions))

    assert {:ok, vectors} =
             CoreEmbeddingModel.embed_documents(model, ["text1", "text2", "text3", "text4"], chunk_size: 2)

    assert vectors == [[0.1], [0.2], [0.3], [0.4]]
  end

  test "token-aware document embeddings split long inputs and recombine weighted vectors" do
    interactions = [
      {
        %{
          "model" => "text-embedding-3-small",
          "input" => ["one two ", "three four "]
        },
        %{
          "data" => [
            %{"index" => 0, "embedding" => [1.0, 0.0]},
            %{"index" => 1, "embedding" => [0.0, 1.0]}
          ]
        }
      },
      {
        %{
          "model" => "text-embedding-3-small",
          "input" => ["five", "short"]
        },
        %{
          "data" => [
            %{"index" => 0, "embedding" => [1.0, 1.0]},
            %{"index" => 1, "embedding" => [0.25, 0.75]}
          ]
        }
      }
    ]

    model = %{
      replay_model(write_gzip_cassette(interactions))
      | tokenizer: %Approximate{mode: :words},
        check_embedding_ctx_length?: true,
        embedding_ctx_length: 2
    }

    assert {:ok, [long_vector, [0.25, 0.75]]} =
             CoreEmbeddingModel.embed_documents(model, ["one two three four five", "short"], chunk_size: 2)

    assert_in_delta Enum.at(long_vector, 0), 0.707, 0.001
    assert_in_delta Enum.at(long_vector, 1), 0.707, 0.001
  end

  test "token-aware embeddings reject disallowed special tokens before replay transport" do
    model = %{
      replay_model("/tmp/unused-cassette.yaml")
      | tokenizer: %Approximate{mode: :words},
        check_embedding_ctx_length?: true,
        disallowed_special: ["<bad>"]
    }

    assert {:error, error} =
             CoreEmbeddingModel.embed_documents(model, ["hello <bad> token"])

    assert error.type == :disallowed_special_token
    assert error.details.token == "<bad>"
  end

  test "skip_empty removes blank document inputs before OpenAI batching" do
    interactions = [
      {
        %{"model" => "text-embedding-3-small", "input" => ["alpha", "beta"]},
        %{
          "data" => [
            %{"index" => 0, "embedding" => [0.1]},
            %{"index" => 1, "embedding" => [0.2]}
          ]
        }
      }
    ]

    model = %{replay_model(write_gzip_cassette(interactions)) | skip_empty: true}

    assert {:ok, [[0.1], [0.2]]} =
             CoreEmbeddingModel.embed_documents(model, ["", "alpha", " ", "beta"])
  end

  test "async batch query embeddings preserve input order" do
    interactions = [
      {
        %{"model" => "text-embedding-3-small", "input" => "first"},
        %{"data" => [%{"index" => 0, "embedding" => [0.1]}]}
      },
      {
        %{"model" => "text-embedding-3-small", "input" => "second"},
        %{"data" => [%{"index" => 0, "embedding" => [0.2]}]}
      }
    ]

    model = replay_model(write_gzip_cassette(interactions))

    assert [
             {:ok, [0.1]},
             {:ok, [0.2]}
           ] =
             EmbeddingModel.async_batch_queries(model, ["first", "second"]) |> Async.await_batch()
  end

  test "returns a provider error when OpenAI omits embedding data" do
    request_body = %{"model" => "text-embedding-3-small", "input" => "alpha"}
    model = replay_model(write_gzip_cassette([{request_body, %{"object" => "list"}}]))

    assert {:error, error} = CoreEmbeddingModel.embed_query(model, "alpha")
    assert error.type == :invalid_response
  end

  test "embedding param policy rejects unsupported params before transport" do
    model = %EmbeddingModel{
      profile: Profile.new(provider: :openai, id: "strict-embedding", supported_params: []),
      param_policy: :strict,
      transport: BeamWeaver.Transport.Replay,
      transport_opts: [cassette_path: "/tmp/should-not-be-read"]
    }

    assert {:error, error} = CoreEmbeddingModel.embed_query(model, "alpha", dimensions: 3)
    assert error.type == :unsupported_model_param
    assert error.details.params == [:dimensions]
  end

  defp replay_model(cassette_path) do
    %EmbeddingModel{
      api_key: "sk-replay-test",
      transport: BeamWeaver.Transport.Replay,
      transport_opts: [cassette_path: cassette_path]
    }
  end

  defp write_gzip_cassette(interactions) do
    path =
      Path.join([
        System.tmp_dir!(),
        "beam_weaver_openai_embeddings_#{System.unique_integer([:positive])}.yaml.gz"
      ])

    File.write!(path, :zlib.gzip(cassette_yaml(interactions)))
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp cassette_yaml(interactions) do
    requests =
      Enum.map_join(interactions, "\n", fn {request_body, _response_body} ->
        """
        - body: !!binary |
            #{Base.encode64(BeamWeaver.JSON.encode!(request_body))}
          headers:
            authorization:
            - '**REDACTED**'
          method: POST
          uri: https://api.openai.com/v1/embeddings
        """
      end)

    responses =
      Enum.map_join(interactions, "\n", fn {_request_body, response_body} ->
        """
        - body:
            string: !!binary |
              #{Base.encode64(BeamWeaver.JSON.encode!(response_body))}
          headers:
            content-type:
            - application/json
          status:
            code: 200
            message: OK
        """
      end)

    """
    requests:
    #{requests}
    responses:
    #{responses}
    """
  end
end
