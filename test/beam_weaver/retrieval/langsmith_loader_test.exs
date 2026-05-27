defmodule BeamWeaver.LangSmithLoaderTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Document
  alias BeamWeaver.DocumentLoader

  defmodule FakeClient do
    defstruct [:parent, examples: []]

    def list_examples(%__MODULE__{parent: parent, examples: examples}, query) do
      send(parent, {:langsmith_query, query})
      {:ok, examples}
    end
  end

  test "builds a LangSmith loader without requiring the Python client" do
    assert %BeamWeaver.DocumentLoader.LangSmith{} =
             DocumentLoader.langsmith(api_key: "secret", dataset_name: "examples")
  end

  test "lazy-loads LangSmith examples as documents through an injected client" do
    created_at = ~U[2026-05-23 10:11:12Z]

    examples = [
      %{
        inputs: %{first: %{"second" => "foo"}},
        outputs: %{result: "a"},
        dataset_id: "dataset-1",
        id: "example-1",
        created_at: created_at,
        modified_at: nil,
        source_run_id: nil
      },
      %{
        "inputs" => %{"first" => %{"second" => "bar"}},
        "outputs" => %{"result" => "b"},
        "dataset_id" => "dataset-1",
        "id" => "example-2",
        "created_at" => created_at
      }
    ]

    loader =
      DocumentLoader.langsmith(
        client: %FakeClient{parent: self(), examples: examples},
        dataset_id: "mock",
        content_key: "first.second",
        format_content: &String.upcase/1,
        limit: 2,
        metadata: %{split: "train"}
      )

    assert {:ok, stream} = DocumentLoader.lazy_load(loader)
    assert [%Document{} = first, %Document{} = second] = Enum.to_list(stream)

    assert_receive {:langsmith_query,
                    %{
                      dataset_id: "mock",
                      inline_s3_urls: true,
                      limit: 2,
                      metadata: %{split: "train"},
                      offset: 0
                    }}

    assert first.content == "FOO"
    assert first.metadata.inputs == %{first: %{"second" => "foo"}}
    assert first.metadata.outputs == %{result: "a"}
    assert first.metadata.dataset_id == "dataset-1"
    assert first.metadata.id == "example-1"
    assert first.metadata.created_at == DateTime.to_iso8601(created_at)
    assert first.metadata.modified_at == nil

    assert second.content == "BAR"
    assert second.metadata["inputs"] == %{"first" => %{"second" => "bar"}}
    assert second.metadata["created_at"] == DateTime.to_iso8601(created_at)
  end

  test "default content formatting keeps strings and pretty-encodes maps" do
    loader =
      DocumentLoader.langsmith(
        client: %FakeClient{
          parent: self(),
          examples: [
            %{inputs: %{"prompt" => "plain text"}},
            %{inputs: %{"prompt" => %{question: "why?", choices: ["a", "b"]}}}
          ]
        },
        content_key: "prompt"
      )

    assert {:ok, stream} = DocumentLoader.load(loader)
    [plain, encoded] = Enum.to_list(stream)

    assert plain.content == "plain text"
    assert encoded.content =~ ~s("question": "why?")
    assert encoded.content =~ ~s("choices": [)
  end
end
