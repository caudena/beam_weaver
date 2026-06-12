defmodule BeamWeaver.Memory.ConformanceTest do
  use ExUnit.Case, async: false

  alias BeamWeaver.Core.Async
  alias BeamWeaver.Memory
  alias BeamWeaver.Memory.Ecto
  alias BeamWeaver.Memory.ETS
  alias BeamWeaver.Memory.GetOp
  alias BeamWeaver.Memory.Item
  alias BeamWeaver.Memory.ListNamespacesOp
  alias BeamWeaver.Memory.MatchCondition
  alias BeamWeaver.Memory.PutOp
  alias BeamWeaver.Memory.SearchOp
  alias BeamWeaver.Test.LivePostgres
  alias BeamWeaver.Test.PostgresRepo

  defmodule CharacterEmbeddings do
    @behaviour BeamWeaver.Core.EmbeddingModel

    defstruct dimensions: 64, parent: nil

    @impl true
    def embed_documents(%__MODULE__{} = model, documents, opts) do
      if model.parent, do: send(model.parent, {:memory_embed_documents, documents, opts})
      {:ok, Enum.map(documents, &vector(&1, model.dimensions))}
    end

    @impl true
    def embed_query(%__MODULE__{} = model, query, opts) do
      if model.parent, do: send(model.parent, {:memory_embed_query, query, opts})
      {:ok, vector(query, model.dimensions)}
    end

    defp vector(text, dimensions) do
      chars = text |> to_string() |> String.downcase() |> String.to_charlist()

      for bucket <- 0..(dimensions - 1) do
        Enum.count(chars, &(rem(&1, dimensions) == bucket))
      end
    end
  end

  for adapter <- [:ets, :ecto] do
    describe "#{adapter} memory store conformance" do
      if adapter == :ecto do
        @describetag :postgres
      end

      setup do
        {:ok, store: new_store(unquote(adapter))}
      end

      test "validates public namespaces without blocking internal batch writes", %{store: store} do
        assert {:error, {:invalid_namespace, _}} = Memory.put(store, [], "key", %{})
        assert {:error, {:invalid_namespace, _}} = Memory.put(store, ["a.b"], "key", %{})
        assert {:error, {:invalid_namespace, _}} = Memory.put(store, ["a", ""], "key", %{})
        assert {:error, {:invalid_namespace, _}} = Memory.put(store, ["beam_weaver"], "key", %{})

        assert [nil] =
                 Memory.batch(store, [
                   %PutOp{namespace: ["beam_weaver"], key: "internal", value: %{"ok" => true}}
                 ])

        assert [%{value: %{"ok" => true}}] =
                 Memory.batch(store, [%GetOp{namespace: ["beam_weaver"], key: "internal"}])
      end

      test "searches by namespace prefix, text query, filters, operators, and pagination", %{
        store: store
      } do
        put!(store, ["docs", "a"], "one", %{"kind" => "report", "score" => 10, "body" => "alpha"})
        put!(store, ["docs", "a"], "two", %{"kind" => "note", "score" => 5, "body" => "beta"})

        put!(store, ["docs", "b"], "three", %{"kind" => "report", "score" => 2, "body" => "gamma"})

        put!(store, ["other"], "four", %{"kind" => "report", "score" => 99, "body" => "alpha"})

        assert Memory.search(store, ["docs"], query: "alpha")
               |> Enum.map(& &1.key) == ["one"]

        assert Memory.search(store, ["docs"], filter: %{"kind" => "report"})
               |> Enum.map(& &1.key)
               |> Enum.sort() == ["one", "three"]

        assert Memory.search(store, ["docs"], filter: %{"score" => %{"$gte" => 5}})
               |> Enum.map(& &1.key)
               |> Enum.sort() == ["one", "two"]

        assert Memory.search(store, ["docs"], filter: %{"score" => %{"$lt" => 10}}, limit: 1)
               |> length() == 1

        assert Memory.search(store, ["docs"], filter: %{"kind" => %{"$ne" => "report"}})
               |> Enum.map(& &1.key) == ["two"]
      end

      test "lists namespaces with prefix, suffix, wildcards, depth, limit, and offset", %{
        store: store
      } do
        namespaces = [
          ["a", "b", "c"],
          ["a", "b", "d", "e"],
          ["a", "b", "d", "i"],
          ["a", "b", "f"],
          ["a", "c", "f"],
          ["b", "a", "f"],
          ["users", "123"],
          ["users", "456", "settings"]
        ]

        Enum.each(Enum.with_index(namespaces), fn {namespace, index} ->
          put!(store, namespace, "id-#{index}", %{"index" => index})
        end)

        assert Memory.list_namespaces(store, prefix: ["a", "b"]) == [
                 ["a", "b", "c"],
                 ["a", "b", "d", "e"],
                 ["a", "b", "d", "i"],
                 ["a", "b", "f"]
               ]

        assert Memory.list_namespaces(store, suffix: ["f"]) == [
                 ["a", "b", "f"],
                 ["a", "c", "f"],
                 ["b", "a", "f"]
               ]

        assert Memory.list_namespaces(store, prefix: ["a", "*", "f"]) == [
                 ["a", "b", "f"],
                 ["a", "c", "f"]
               ]

        assert Memory.list_namespaces(store, prefix: ["a", "b"], max_depth: 3) == [
                 ["a", "b", "c"],
                 ["a", "b", "d"],
                 ["a", "b", "f"]
               ]

        assert Memory.list_namespaces(store, prefix: ["a", "b"], limit: 2) == [
                 ["a", "b", "c"],
                 ["a", "b", "d", "e"]
               ]

        assert Memory.list_namespaces(store, prefix: ["a", "b"], offset: 2) == [
                 ["a", "b", "d", "i"],
                 ["a", "b", "f"]
               ]
      end

      test "executes batch operations in order", %{store: store} do
        ops = [
          %PutOp{namespace: ["users", "1"], key: "prefs", value: %{"theme" => "dark"}},
          %GetOp{namespace: ["users", "1"], key: "prefs"},
          %SearchOp{namespace: ["users"], filter: %{"theme" => "dark"}},
          %ListNamespacesOp{
            match_conditions: [
              %MatchCondition{type: :prefix, path: ["users"]}
            ]
          },
          %PutOp{namespace: ["users", "1"], key: "prefs", value: nil},
          %GetOp{namespace: ["users", "1"], key: "prefs"}
        ]

        assert [nil, item, [search_item], [["users", "1"]], nil, nil] = Memory.batch(store, ops)
        assert %Item{} = item
        assert item.value == %{"theme" => "dark"}
        assert search_item.key == "prefs"
      end

      test "async store facade mirrors sync get put delete search namespace and batch calls", %{
        store: store
      } do
        assert {:ok, _item} =
                 Memory.async_put(store, ["async"], "one", %{"body" => "alpha"}, metadata: %{m: 1})
                 |> Async.await()

        assert {:ok, item} = Memory.async_get(store, ["async"], "one") |> Async.await()
        assert item.value == %{"body" => "alpha"}
        assert metadata_value(item.metadata, "m") == 1

        assert [%{key: "one"}] =
                 Memory.async_search(store, ["async"], query: "alpha") |> Async.await()

        assert [["async"]] =
                 Memory.async_list_namespaces(store, prefix: ["async"]) |> Async.await()

        assert [item] =
                 Memory.async_batch(store, [%GetOp{namespace: ["async"], key: "one"}])
                 |> Async.await()

        assert item.key == "one"

        assert :ok = Memory.async_delete(store, ["async"], "one") |> Async.await()
        assert :error = Memory.get(store, ["async"], "one")
      end

      test "base-store batch key helpers preserve order, idempotency, missing keys, and prefix listing",
           %{store: store} do
        assert [nil, nil, nil] = Memory.get_many(store, ["kv"], ["foo", "bar", "buzz"])

        assert :ok = Memory.put_many(store, ["kv"], [{"foo", "value1"}, {"bar", "value2"}])
        assert ["value1", "value2"] = Memory.get_many(store, ["kv"], ["foo", "bar"])

        assert :ok = Memory.put_many(store, ["kv"], [{"foo", "value3"}])

        assert ["value3", "value2", "value3"] =
                 Memory.get_many(store, ["kv"], ["foo", "bar", "foo"])

        assert ["bar", "foo"] = Memory.yield_keys(store, ["kv"])
        assert ["foo"] = Memory.yield_keys(store, ["kv"], prefix: "fo")
        assert [] = Memory.yield_keys(store, ["kv"], prefix: "x")

        assert :ok = Memory.delete_many(store, ["kv"], ["foo", "missing"])
        assert [nil, "value2"] = Memory.get_many(store, ["kv"], ["foo", "bar"])
      end

      test "base-store async batch key helpers use Task-backed handles", %{store: store} do
        assert :ok =
                 Memory.async_put_many(store, ["async-kv"], [
                   {"foo", "value1"},
                   {"bar", "value2"}
                 ])
                 |> Async.await()

        assert ["value1", "value2", nil] =
                 Memory.async_get_many(store, ["async-kv"], ["foo", "bar", "missing"])
                 |> Async.await()

        assert ["bar", "foo"] =
                 Memory.async_yield_keys(store, ["async-kv"])
                 |> Async.await()

        assert :ok =
                 Memory.async_delete_many(store, ["async-kv"], ["foo", "bar"])
                 |> Async.await()

        assert [nil, nil] = Memory.get_many(store, ["async-kv"], ["foo", "bar"])
      end
    end
  end

  test "ets memory store expires TTL items opportunistically" do
    store = ETS.new()

    assert {:ok, _item} = Memory.put(store, ["ttl"], "short", %{"value" => true}, ttl: 0.005)
    assert {:ok, _item} = Memory.get(store, ["ttl"], "short")

    Process.sleep(350)

    assert Memory.get(store, ["ttl"], "short") == :error
    assert Memory.search(store, ["ttl"]) == []
  end

  test "extracts text at memory paths for vector indexing" do
    nested = %{
      "name" => "test",
      "info" => %{
        "age" => 25,
        "tags" => ["a", "b", "c"],
        "metadata" => %{"created" => "2024-01-01", "updated" => "2024-01-02"}
      },
      "items" => [
        %{"id" => 1, "value" => "first", "tags" => ["x", "y"]},
        %{"id" => 2, "value" => "second", "tags" => ["y", "z"]},
        %{"id" => 3, "value" => "third", "tags" => ["z", "w"]}
      ],
      "empty" => nil,
      "zeros" => [0, 0.0, "0"],
      "empty_list" => [],
      "empty_dict" => %{}
    }

    assert [root] = Memory.get_text_at_path(nested, "$")
    assert {:ok, ^nested} = BeamWeaver.JSON.decode(root)
    assert Memory.get_text_at_path(nested, "") == [root]
    assert Memory.get_text_at_path(nested, "name") == ["test"]
    assert Memory.get_text_at_path(nested, "info.age") == ["25"]
    assert Memory.get_text_at_path(nested, "info.metadata.created") == ["2024-01-01"]
    assert Memory.get_text_at_path(nested, "items[0].value") == ["first"]
    assert Memory.get_text_at_path(nested, "items[-1].value") == ["third"]
    assert Memory.get_text_at_path(nested, "items[1].tags[0]") == ["y"]

    assert Memory.get_text_at_path(nested, "items[*].value") |> Enum.sort() == [
             "first",
             "second",
             "third"
           ]

    assert Memory.get_text_at_path(nested, "info.metadata.*") |> Enum.sort() == [
             "2024-01-01",
             "2024-01-02"
           ]

    assert Memory.get_text_at_path(nested, "{name,info.age}") |> Enum.sort() == ["25", "test"]

    assert {:ok, tokens} = Memory.tokenize_path("items[*].{id,value}")
    assert tokens == [{:key, "items"}, :wildcard, {:union, ["id", "value"]}]

    assert Memory.get_text_at_path(nested, tokens) |> Enum.sort() == [
             "1",
             "2",
             "3",
             "first",
             "second",
             "third"
           ]

    assert Memory.get_text_at_path(nested, ["items", "[*]", "{id,value}"]) |> Enum.sort() == [
             "1",
             "2",
             "3",
             "first",
             "second",
             "third"
           ]

    assert Memory.get_text_at_path(nested, "items[*].tags[*]") |> Enum.sort() == [
             "w",
             "x",
             "y",
             "y",
             "z",
             "z"
           ]

    assert Memory.get_text_at_path(nested, "empty") == []
    assert Memory.get_text_at_path(nested, "empty_list") == ["[]"]
    assert Memory.get_text_at_path(nested, "empty_dict") == ["{}"]
    assert Memory.get_text_at_path(nested, "zeros[*]") |> Enum.sort() == ["0", "0", "0.0"]
    assert Memory.get_text_at_path(nested, "nonexistent") == []
    assert Memory.get_text_at_path(nested, "items[99].value") == []
    assert Memory.get_text_at_path(nested, "items[*].nonexistent") == []
    assert Memory.get_text_at_path(nested, "items[].value") == []
    assert Memory.get_text_at_path(nested, "items[abc].value") == []
    assert Memory.get_text_at_path(nested, "{unclosed") == []
    assert Memory.get_text_at_path(nested, "nested[{invalid}]") == []
  end

  test "ets memory store supports native embedding indexes, filters, field paths, pagination, and unicode" do
    embeddings = %CharacterEmbeddings{parent: self()}
    store = ETS.new(index: %{dims: embeddings.dimensions, embed: embeddings})

    docs = [
      {"doc1", %{"text" => "short text"}},
      {"doc2", %{"text" => "longer text document"}},
      {"doc3", %{"text" => "longest text document here"}},
      {"doc4", %{"description" => "text in description field"}},
      {"doc5", %{"content" => "text in content field"}},
      {"doc6", %{"body" => "text in body field"}}
    ]

    Enum.each(docs, fn {key, value} -> put!(store, ["vectors"], key, value) end)
    results = Memory.search(store, ["vectors"], query: "long text", limit: 6)
    assert "doc2" in Enum.map(results, & &1.key)
    assert "doc3" in Enum.map(results, & &1.key)
    assert_receive {:memory_embed_query, "long text", _opts}

    put!(store, ["updates"], "doc1", %{"text" => "zany zebra Xerxes"})
    put!(store, ["updates"], "doc2", %{"text" => "something about dogs"})
    put!(store, ["updates"], "doc3", %{"text" => "text about birds"})

    [initial | _] = Memory.search(store, ["updates"], query: "Zany Xerxes")
    assert initial.key == "doc1"
    initial_score = initial.score

    put!(store, ["updates"], "doc1", %{"text" => "new text about dogs"})
    after_score = store |> Memory.search(["updates"], query: "Zany Xerxes") |> score_for("doc1")
    assert after_score < initial_score

    assert score_for(Memory.search(store, ["updates"], query: "new text about dogs"), "doc1") >
             after_score

    assert {:ok, _item} =
             Memory.put(store, ["updates"], "doc4", %{"text" => "new text about dogs"}, index: false)

    refute "doc4" in (store
                      |> Memory.search(["updates"], query: "new text about dogs", limit: 3)
                      |> Enum.map(& &1.key))

    Enum.each(
      [
        {"doc1", %{"text" => "red apple", "color" => "red", "score" => 4.5}},
        {"doc2", %{"text" => "red car", "color" => "red", "score" => 3.0}},
        {"doc3", %{"text" => "green apple", "color" => "green", "score" => 4.0}},
        {"doc4", %{"text" => "blue car", "color" => "blue", "score" => 3.5}}
      ],
      fn {key, value} -> put!(store, ["filters"], key, value) end
    )

    assert [%{key: "doc1"} | _] =
             Memory.search(store, ["filters"], query: "apple", filter: %{"color" => "red"})

    assert [%{key: "doc2"} | _] =
             Memory.search(store, ["filters"], query: "car", filter: %{"color" => "red"})

    assert [%{key: "doc4"} | _] =
             Memory.search(store, ["filters"],
               query: "bbbbluuu",
               filter: %{"score" => %{"$gt" => 3.2}}
             )

    assert [%{key: "doc3"}] =
             Memory.search(store, ["filters"],
               query: "apple",
               filter: %{"score" => %{"$gte" => 4.0}, "color" => "green"}
             )

    Enum.each(0..4, fn index ->
      put!(store, ["pages"], "doc#{index}", %{"text" => "test document number #{index}"})
    end)

    page1 = Memory.search(store, ["pages"], query: "test", limit: 2)
    page2 = Memory.search(store, ["pages"], query: "test", limit: 2, offset: 2)
    assert length(page1) == 2
    assert length(page2) == 2
    assert hd(page1).key != hd(page2).key
    assert length(Memory.search(store, ["pages"], query: "test", limit: 10)) == 5

    path_store =
      ETS.new(index: %{dims: embeddings.dimensions, embed: embeddings, fields: ["key0", "key1", "key3"]})

    put!(path_store, ["paths"], "doc1", %{"key1" => "xxx", "key2" => "yyy", "key3" => "zzz"})

    put!(path_store, ["paths"], "doc2", %{
      "key0" => "uuu",
      "key1" => "vvv",
      "key2" => "www",
      "key3" => "xxx"
    })

    assert [%{key: first}, %{key: second}] = Memory.search(path_store, ["paths"], query: "xxx")
    assert first != second
    assert [%{key: "doc2"} | _] = Memory.search(path_store, ["paths"], query: "uuu")

    assert Enum.all?(
             Memory.search(path_store, ["paths"], query: "www"),
             &(&1.score < hd(Memory.search(path_store, ["paths"], query: "xxx")).score)
           )

    override_store =
      ETS.new(index: %{dims: embeddings.dimensions, embed: embeddings, fields: ["ignored"]})

    assert {:ok, _item} =
             Memory.put(override_store, ["override"], "doc3", %{"key0" => "aaa", "key1" => "bbb"},
               index: ["key0", "key1"]
             )

    assert {:ok, _item} =
             Memory.put(
               override_store,
               ["override"],
               "doc4",
               %{"key0" => "eee", "key1" => "bbb", "key3" => "ggg"},
               index: ["key1", "key3"]
             )

    assert {:ok, _item} =
             Memory.put(override_store, ["override"], "doc5", %{"key0" => "hhh", "key1" => "iii"}, index: false)

    assert [%{key: "doc3"} | _] = Memory.search(override_store, ["override"], query: "aaa")
    assert [%{key: "doc4"} | _] = Memory.search(override_store, ["override"], query: "ggg")

    assert %{score: nil} =
             Enum.find(
               Memory.search(override_store, ["override"], query: "hhh", limit: 3),
               &(&1.key == "doc5")
             )

    unicode_store = ETS.new(index: %{dims: embeddings.dimensions, embed: embeddings})

    [
      {"1", "这是中文"},
      {"2", "これは日本語です"},
      {"3", "이건 한국어야"},
      {"4", "Это русский"},
      {"5", "यह रूसी है"}
    ]
    |> Enum.each(fn {key, text} ->
      put!(unicode_store, ["user_123", "memories"], key, %{"text" => text})

      assert [%{key: ^key} | _] =
               Memory.search(unicode_store, ["user_123", "memories"], query: text)
    end)
  end

  test "ets memory vector operations work through Task-backed async facade" do
    embeddings = %CharacterEmbeddings{parent: self()}
    store = ETS.new(index: %{dims: embeddings.dimensions, embed: embeddings})

    for index <- 0..9 do
      assert {:ok, _item} =
               Memory.async_put(
                 store,
                 ["async-vectors"],
                 "doc#{index}",
                 %{
                   "text" => "red apple #{index}",
                   "color" => if(rem(index, 2) == 0, do: "red", else: "blue"),
                   "index" => index
                 }
               )
               |> Async.await()
    end

    assert [%{key: "doc0"} | _] =
             Memory.async_search(store, ["async-vectors"],
               query: "apple 0",
               filter: %{"color" => "red"}
             )
             |> Async.await()

    results =
      0..4
      |> Enum.map(fn index ->
        Memory.async_search(store, ["async-vectors"],
          query: "apple #{index}",
          filter: %{"index" => %{"$gte" => index}}
        )
      end)
      |> Async.await_batch()

    assert Enum.all?(results, &(&1 != []))
  end

  defp new_store(:ets), do: ETS.new()

  defp new_store(:ecto) do
    assert LivePostgres.available?()

    table = LivePostgres.unique_table("bw_conformance_memory")
    version = LivePostgres.migrate(adapters: [{:memory, table: table}])

    on_exit(fn ->
      LivePostgres.drop_tables([table])
      LivePostgres.clear_migration(version)
    end)

    Ecto.new(repo: PostgresRepo, table: table)
  end

  defp metadata_value(metadata, key) do
    Map.get(metadata, key, Map.get(metadata, String.to_existing_atom(key)))
  end

  defp put!(store, namespace, key, value) do
    assert {:ok, _item} = Memory.put(store, namespace, key, value)
  end

  defp score_for(results, key) do
    results
    |> Enum.find(&(&1.key == key))
    |> Map.fetch!(:score)
  end
end
