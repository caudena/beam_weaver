defmodule BeamWeaver.ExampleSelector do
  @moduledoc """
  Example selectors for prompts and evaluation examples.
  """

  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.Document
  alias BeamWeaver.ExampleLike
  alias BeamWeaver.Retriever
  alias BeamWeaver.VectorStore

  def length_based(examples, opts \\ []),
    do:
      struct(BeamWeaver.ExampleSelector.Length,
        examples: examples,
        max_length: Keyword.get(opts, :max_length, 2_000)
      )

  def vectorstore(store, opts \\ []),
    do: struct(BeamWeaver.ExampleSelector.VectorStore, store: store, opts: opts)

  def mmr_vectorstore(store, opts \\ []),
    do:
      struct(BeamWeaver.ExampleSelector.VectorStore,
        store: store,
        opts: Keyword.put(opts, :search_type, :mmr)
      )

  def metadata_filter(selector, predicate) when is_function(predicate, 1),
    do: struct(BeamWeaver.ExampleSelector.MetadataFilter, selector: selector, predicate: predicate)

  def select(selector, input, opts \\ []), do: selector.__struct__.select(selector, input, opts)

  def async_select(selector, input, opts \\ []) do
    Async.run_call(opts, &select(selector, input, &1))
  end

  def add_example(selector, example, opts \\ []) do
    if function_exported?(selector.__struct__, :add_example, 3) do
      selector.__struct__.add_example(selector, example, opts)
    else
      {:error,
       BeamWeaver.Core.Error.new(
         :unsupported_example_selector,
         "example selector cannot add examples"
       )}
    end
  end

  def async_add_example(selector, example, opts \\ []) do
    Async.run_call(opts, &add_example(selector, example, &1))
  end

  def semantic_similarity(examples, embedding, opts \\ []) do
    from_examples(examples, embedding, Keyword.put(opts, :search_type, :similarity))
  end

  def max_marginal_relevance(examples, embedding, opts \\ []) do
    from_examples(examples, embedding, Keyword.put(opts, :search_type, :mmr))
  end

  def from_examples(examples, embedding, opts \\ []) do
    store_module = Keyword.get(opts, :vector_store, BeamWeaver.VectorStore.ETS)
    store_opts = Keyword.get(opts, :vector_store_opts, [])
    store = store_module.new(Keyword.put_new(store_opts, :embedding, embedding))
    input_keys = Keyword.get(opts, :input_keys)

    documents =
      Enum.map(examples, fn example ->
        Document.new!(example_to_text(example, input_keys), metadata: Map.new(example))
      end)

    with {:ok, _ids} <- VectorStore.add_documents(store, documents, opts) do
      selector_opts =
        opts
        |> Keyword.drop([:vector_store, :vector_store_opts])
        |> Keyword.put(:input_keys, input_keys)

      case Keyword.get(opts, :search_type, :similarity) do
        :mmr -> {:ok, mmr_vectorstore(store, selector_opts)}
        "mmr" -> {:ok, mmr_vectorstore(store, selector_opts)}
        _other -> {:ok, vectorstore(store, selector_opts)}
      end
    end
  end

  def async_from_examples(examples, embedding, opts \\ []) do
    Async.run_call(opts, &from_examples(examples, embedding, &1))
  end

  def sorted_values(values) when is_map(values) do
    values
    |> Map.keys()
    |> Enum.sort_by(&to_string/1)
    |> Enum.map(&Map.fetch!(values, &1))
  end

  def example_to_text(example, input_keys \\ nil)

  def example_to_text(example, input_keys) when is_map(example) and is_list(input_keys) do
    example
    |> Map.take(input_keys)
    |> Map.merge(Map.take(example, Enum.map(input_keys, &to_string/1)))
    |> sorted_values()
    |> Enum.join(" ")
  end

  def example_to_text(example, _input_keys) when is_map(example) do
    example
    |> sorted_values()
    |> Enum.join(" ")
  end

  def example_to_text(input, _input_keys), do: to_string(input)

  def normalize_examples(examples) do
    examples
    |> List.wrap()
    |> Enum.reduce_while({:ok, []}, fn example, {:ok, acc} ->
      case ExampleLike.to_example(example) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      other -> other
    end
  end

  defmodule Length do
    @moduledoc false
    defstruct examples: [], max_length: 2_000

    def select(%__MODULE__{} = selector, input, opts) do
      k = Keyword.get(opts, :k, length(selector.examples))
      input_length = example_length(input)

      with {:ok, examples} <- BeamWeaver.ExampleSelector.normalize_examples(selector.examples) do
        {selected, _remaining} =
          Enum.reduce_while(examples, {[], selector.max_length - input_length}, fn example, {acc, remaining} ->
            length = example_length(example)

            cond do
              length > remaining -> {:halt, {acc, remaining}}
              length <= remaining -> {:cont, {[example | acc], remaining - length}}
            end
          end)

        {:ok, selected |> Enum.reverse() |> Enum.take(k)}
      end
    end

    def add_example(%__MODULE__{} = selector, example, _opts) do
      with {:ok, [normalized]} <- BeamWeaver.ExampleSelector.normalize_examples([example]) do
        {:ok, %{selector | examples: selector.examples ++ [normalized]}}
      end
    end

    defp example_length(example) do
      example
      |> BeamWeaver.ExampleSelector.example_to_text()
      |> String.split(~r/\n| /, trim: false)
      |> length()
    end
  end

  defmodule VectorStore do
    @moduledoc false
    defstruct [:store, opts: []]

    def select(%__MODULE__{} = selector, input, opts) do
      opts = Keyword.merge(selector.opts, opts)

      retriever =
        BeamWeaver.VectorStore.as_retriever(
          selector.store,
          Keyword.drop(opts, [:input_keys, :example_keys])
        )

      with {:ok, docs} <-
             Retriever.retrieve(
               retriever,
               BeamWeaver.ExampleSelector.example_to_text(input, opts[:input_keys]),
               opts
             ) do
        docs
        |> Enum.map(& &1.metadata)
        |> filter_example_keys(opts[:example_keys])
        |> BeamWeaver.ExampleSelector.normalize_examples()
      end
    end

    def add_example(%__MODULE__{} = selector, example, opts) do
      opts = Keyword.merge(selector.opts, opts)
      text = BeamWeaver.ExampleSelector.example_to_text(example, opts[:input_keys])
      metadata = Map.new(example)

      with {:ok, [id]} <-
             BeamWeaver.VectorStore.add_documents(
               selector.store,
               [BeamWeaver.Core.Document.new!(text, metadata: metadata)],
               opts
             ) do
        {:ok, id}
      end
    end

    defp filter_example_keys(examples, nil), do: examples

    defp filter_example_keys(examples, keys) do
      keys = List.wrap(keys)

      Enum.map(examples, fn example ->
        atom_keys = Enum.filter(keys, &is_atom/1)
        string_keys = Enum.map(keys, &to_string/1)

        example
        |> Map.take(atom_keys)
        |> Map.merge(Map.take(example, string_keys))
      end)
    end
  end

  defmodule MetadataFilter do
    @moduledoc false
    defstruct [:selector, :predicate]

    def select(%__MODULE__{} = selector, input, opts) do
      with {:ok, examples} <- BeamWeaver.ExampleSelector.select(selector.selector, input, opts) do
        {:ok, Enum.filter(examples, &selector.predicate.(&1))}
      end
    end
  end
end
