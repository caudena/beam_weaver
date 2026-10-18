# Retrieval

Retrieval finds the passages of your own content, such as help center
articles or policies, that answer a question, so a model can answer from
them. Use it when the answers live in documents the model has never seen,
too many to paste into every prompt.

```elixir
alias BeamWeaver.Core.Document
alias BeamWeaver.{Models, TextSplitter, VectorStore}

articles = [
  Document.new!(
    "Refunds go back to the original card within 5 business days.\nStore credit is instant.",
    metadata: %{"source" => "refunds.md"}
  ),
  Document.new!(
    "Standard shipping takes 3 to 5 days.\nExpress shipping arrives the next business day.",
    metadata: %{"source" => "shipping.md"}
  )
]

splitter = TextSplitter.recursive_character(chunk_size: 60, chunk_overlap: 0)
{:ok, chunks} = TextSplitter.split_documents(splitter, articles)

embeddings = Models.init_embeddings!("fake:embedding")
store = VectorStore.ETS.new(embedding: embeddings)
{:ok, _ids} = VectorStore.add_documents(store, chunks)

{:ok, results} = VectorStore.similarity_search(store, "How long do refunds take?", k: 2)
results
#=> [%Document{metadata: %{"source" => _}}, %Document{metadata: %{"source" => _}}]
```

The two articles became four chunks in the store, and the search returned the
two closest to the question, each still carrying its source. The steps:

1. **Documents** hold text and metadata, such as the file the text came from.
2. A **text splitter** cuts them into chunks, each small enough to match one
   question and to fit in a prompt next to a few others.
3. An **embedding model** turns each chunk into a vector, a list of numbers.
   Texts with similar meanings get vectors that are close together.
4. A **vector store** keeps the vectors and returns the chunks closest to the
   vector of a question.

A model then answers from those chunks: your code puts them in the prompt, or
the agent calls a search tool ([Agentic retrieval](#agentic-retrieval)).

{% hint style="info" %}
`"fake:embedding"` builds vectors from a hash of the text. It needs no API key
and always returns the same vectors, but they carry no meaning: a search
returns the right number of results in an arbitrary order. That's why the
examples on this page check counts and shapes, not rankings. To rank by
meaning, use a provider model ([Embeddings](#embeddings)).
{% endhint %}

## Documents

A `BeamWeaver.Core.Document` has `content`, a string; `metadata`, a map you
choose; and an optional `id`. Stores derive an id from the content and
metadata when there is none.

```elixir
gift_cards =
  Document.new!("Gift cards never expire.", id: "gift-cards", metadata: %{"source" => "gift_cards.md"})

{gift_cards.id, gift_cards.metadata}
#=> {"gift-cards", %{"source" => "gift_cards.md"}}
```

`BeamWeaver.Core.Document.new/2` returns an error tuple for bad input instead
of raising. Put a `"source"` in the metadata: search results carry it, so the
model can cite it. Use string keys, because Postgres stores metadata as JSON and
returns string keys.

BeamWeaver has no document loaders. Read your sources with plain Elixir, one
document per file or database row:

<!-- snippet: compile -->
```elixir
articles =
  for path <- Path.wildcard("priv/help_center/*.md") do
    Document.new!(File.read!(path), metadata: %{"source" => Path.basename(path)})
  end
```

To split a web page, `BeamWeaver.TextSplitter.split_url/3` fetches it and
splits the body as one document, with the URL as its `source`. The URL may
come from a user or a model, so it must pass a URL policy before any request
is sent: by default only `https` URLs to public addresses. Private, loopback,
link-local and cloud metadata addresses are refused, also when an IPv6
address carries one (such as `[::ffff:169.254.169.254]`), a host name
resolves to one or a redirect points to one:

```elixir
TextSplitter.split_url(TextSplitter.html_headers(), "https://169.254.169.254/latest/meta-data/")
#=> {:error, %BeamWeaver.Core.Error{type: :unsafe_url}}
```

Pass `url_policy:` to change the rules. `allowed_hosts:` accepts only the
hosts you list, and `follow_redirects?: false` stops at the first response;
`BeamWeaver.Transport.URLPolicy` lists the options. The request connects to
the address that passed the check, so a host name can't switch to another
address between the check and the request. Fetches reuse connections only for
the same address and host name, in at most 16 connection pools kept apart
from the ones model calls use; while all 16 have a fetch in flight, a fetch
to another host waits for one to finish (`BeamWeaver.Transport.ReqFinch` shows
how to raise the limit).

<!-- snippet: compile -->
```elixir
{:ok, page_chunks} =
  TextSplitter.split_url(TextSplitter.html_headers(), "https://help.acme.example/refunds",
    url_policy: [allowed_hosts: ["help.acme.example"]]
  )
```

## Text splitters

Split long documents before you embed them. A vector for a whole article blurs
its topics together, and a prompt has room for a few passages, not for whole
files.

```elixir
text = "Refunds go back to the original card within 5 business days. Store credit is instant."
overlapping = TextSplitter.recursive_character(chunk_size: 40, chunk_overlap: 10)

TextSplitter.split_text(overlapping, text)
#=> ["Refunds go back to the original card", "card within 5 business days. Store",
#    "Store credit is instant."]
```

`recursive_character/1` splits at paragraphs first, then at lines, then at
words, and joins the pieces back into chunks of up to `chunk_size` characters.
`chunk_overlap` repeats the end of each chunk at the start of the next one
(here "card" and "Store"), so text near a cut appears in both chunks.

`BeamWeaver.TextSplitter.split_documents/2` splits documents instead of
strings. It returns `{:ok, stream}`, a lazy stream of chunks that keep their
document's metadata. `BeamWeaver.VectorStore.add_documents/3` takes the
stream as it is. The chunks of a
document with an `id` get ids made from it, one per chunk, and the document's
id as `"parent_id"` in their metadata:

```elixir
refunds_article = Document.new!("Refunds take 5 days. Store credit is instant.", id: "refunds")
short_splitter = TextSplitter.recursive_character(chunk_size: 25, chunk_overlap: 0)
{:ok, refunds_chunks} = TextSplitter.split_documents(short_splitter, [refunds_article])
Enum.map(refunds_chunks, &{&1.id, &1.metadata["parent_id"]})
#=> [{"refunds:0", "refunds"}, {"refunds:1", "refunds"}]
```

| Splitter | Splits | Key options |
| --- | --- | --- |
| `recursive_character/1` | Prose, by paragraphs, then lines, then words | `chunk_size:` (characters, default 1000), `chunk_overlap:` (default 200), `separators:` |
| `character/1` | At the one `separator:` you give | `separator:`, `chunk_size:`, `chunk_overlap:` |
| `markdown_headers/1` | Markdown, one chunk per section, with the heading titles in the metadata | `headers:`, such as `[{"#", "title"}, {"##", "section"}]` |
| `html_headers/1` | HTML the same way, without the tags | `headers:`, such as `[{"h1", "title"}, {"h2", "section"}]` |
| `from_language/2` | Source code, preferring breaks before definitions, such as `from_language(:elixir, chunk_size: 800)` | the `recursive_character` options |
| `token/1` | By tokens instead of characters | `chunk_size:`, `chunk_overlap:` (in tokens) |
| `recursive_json/1` | JSON values into smaller objects, with `split_json/3` | `chunk_size:` |

The character-based splitters also take `length_function:`, to measure chunks
your own way (in words, say), and `add_start_index: true`, which records each
chunk's offset in its metadata. The header splitters split only at the
headings you list in `headers:`; other headings stay in the chunk's text.

## Embeddings

An embedding model turns text into a vector. In your application, build one
with `BeamWeaver.Models.init_embeddings!/2` and a provider model, passing the
API key with `api_key:`:

```elixir
embeddings =
  BeamWeaver.Models.init_embeddings!("openai:text-embedding-3-small",
    api_key: System.fetch_env!("OPENAI_API_KEY")
  )
```

Stores call the model for you, but you can call it yourself. Here
`embeddings` is still the fake model from the first example:

```elixir
{:ok, vector} = BeamWeaver.Core.EmbeddingModel.embed_query(embeddings, "How long do refunds take?")
length(vector)
#=> 3
```

`embed_query/3` embeds one text and `embed_documents/3` a list of texts. The
fake model makes three numbers per text (`dimensions:` changes that), while
`text-embedding-3-small` makes 1536. Index and search with the same model:
vectors from different models can't be compared, so changing the model means
indexing everything again. `mix beam_weaver.models.profiles` lists the
embedding models BeamWeaver knows, such as `openai:text-embedding-3-large` and
`xai:v1`.

## Vector stores

A vector store saves documents with their vectors and searches them.
`BeamWeaver.VectorStore.ETS` keeps them in memory on one node, which suits
development, tests and small indexes. Its table belongs to the process that
calls `new/1`, so create the store once, in a process that lives as long as you
need the index, and pass it around. `BeamWeaver.VectorStore.ETS.dump/2` saves
it to a JSON file and `load/2` reads it back, so a restart doesn't embed
everything again.

| `BeamWeaver.VectorStore` function | Does |
| --- | --- |
| `add_documents/3` | Embeds and stores documents and returns their ids. Adding an existing id replaces it. |
| `similarity_search/3` | Returns the `k:` closest documents (default 4) that match `filter:` |
| `similarity_search_with_score/3` | The same, as `{document, score}` pairs; a higher score is closer |
| `max_marginal_relevance_search/3` | Returns `k:` documents that are close to the query but differ from each other. `fetch_k:` sets how many candidates it considers; `lambda:` goes from 0 (most varied) to 1 (most relevant). |
| `get_by_ids/3`, `delete/3` | Fetch or remove documents by id |

```elixir
{:ok, ["gift-cards"]} = VectorStore.add_documents(store, [gift_cards])

{:ok, hits} =
  VectorStore.similarity_search(store, "Do gift cards expire?", filter: %{"source" => "gift_cards.md"})

Enum.map(hits, & &1.id)
#=> ["gift-cards"]
```

```elixir
{:ok, scored} = VectorStore.similarity_search_with_score(store, "Do gift cards expire?", k: 2)
scored
#=> [{%Document{}, _}, {%Document{}, _}]
```

```elixir
{:ok, varied} =
  VectorStore.max_marginal_relevance_search(store, "Do gift cards expire?", k: 2, fetch_k: 5)

length(varied)
#=> 2
```

```elixir
:ok = VectorStore.delete(store, ["gift-cards"])
VectorStore.get_by_ids(store, ["gift-cards"])
#=> {:ok, []}
```

A `filter:` map matches metadata. A plain value must be equal, and an operator
map compares: `%{"year" => %{"$gte" => 2025}}`. The operators are `$eq`, `$ne`,
`$gt`, `$gte`, `$lt`, `$lte`, `$in`, `$nin`, `$contain` and `$like`. Combine
filters with `"$and"`, `"$or"` and `"$not"`, and reach into nested maps with a
dotted key such as `"product.sku"`.

### Postgres

`BeamWeaver.VectorStore.EctoPostgres` keeps the vectors in Postgres with the
pgvector extension, through your Ecto repo. The store is a plain struct, cheap
to build wherever you need it:

```elixir
embeddings =
  BeamWeaver.Models.init_embeddings!("openai:text-embedding-3-small",
    api_key: System.fetch_env!("OPENAI_API_KEY")
  )

store = BeamWeaver.VectorStore.EctoPostgres.new(repo: MyApp.Repo, embedding: embeddings)
```

A migration creates its table. It also enables the pgvector extension, which
must be installed on the database server:

```elixir
defmodule MyApp.Repo.Migrations.AddHelpCenterIndex do
  use Ecto.Migration

  def up, do: BeamWeaver.Migrations.up(adapters: [:vector_store])
  def down, do: BeamWeaver.Migrations.down(adapters: [:vector_store])
end
```

The vector column holds 1536 numbers, the size `text-embedding-3-small` makes.
For a model with another size, set it in the migration, such as
`{:vector_store, dimensions: 1024}`. pgvector can't index more than 2,000
numbers, so ask a bigger model for fewer when you build it:
`init_embeddings!("openai:text-embedding-3-large", dimensions: 1024)`, or
create the table with `index: false` to search without an index. Give each
store a `namespace:` to keep several indexes in one table. See
[Storage](storage.md) for running BeamWeaver's migrations.

## Retrievers

A retriever is anything you can pass to `BeamWeaver.Retriever.retrieve/3`:
it takes a question and returns documents. Code that searches through a
retriever doesn't depend on where the documents live.
`BeamWeaver.VectorStore.as_retriever/2` turns a store into a retriever with
fixed search settings:

```elixir
alias BeamWeaver.Retriever

retriever = VectorStore.as_retriever(store, k: 2)

{:ok, docs} = Retriever.retrieve(retriever, "How long do refunds take?")
length(docs)
#=> 2
```

| Option | Default | Effect |
| --- | --- | --- |
| `k:` | `4` | How many documents to return |
| `filter:` | `%{}` | A metadata filter, as in `similarity_search/3` |
| `search_type:` | `:similarity` | `:mmr` returns varied results; `:similarity_score` drops results below `score_threshold:` |
| `score_threshold:` | `nil` | With `:similarity_score`, the lowest score to keep |
| `mmr_lambda:` | `0.5` | With `:mmr`, from 0 (most varied) to 1 (most relevant) |

`k:`, `filter:`, `score_threshold:` and `mmr_lambda:` passed to `retrieve/3`
override the retriever's own; the search type is always the retriever's:

```elixir
{:ok, docs} = Retriever.retrieve(retriever, "delivery times", filter: %{"source" => "shipping.md"})
Enum.map(docs, & &1.metadata["source"])
#=> ["shipping.md", "shipping.md"]
```

Any struct whose module implements the `BeamWeaver.Retriever` behaviour works
the same way, so a search you already have, such as Postgres full-text
search, can sit behind the same call:

```elixir
defmodule MyApp.KeywordRetriever do
  @behaviour BeamWeaver.Retriever

  defstruct documents: []

  @impl true
  def retrieve(%__MODULE__{documents: documents}, query, opts) do
    words = query |> String.downcase() |> String.split()

    matches =
      Enum.filter(documents, fn doc ->
        text = String.downcase(doc.content)
        Enum.any?(words, &String.contains?(text, &1))
      end)

    {:ok, Enum.take(matches, Keyword.get(opts, :k, 4))}
  end
end
```

```elixir
{:ok, [doc]} = Retriever.retrieve(%MyApp.KeywordRetriever{documents: articles}, "express")
doc.metadata["source"]
#=> "shipping.md"
```

## Agentic retrieval

To let the agent decide when to search, give it a search tool. This one reads
its retriever from the run's [context](runtime_context.md), so each call can
search the right index, such as the one for the customer's language, and
tests can pass one over ETS. The model only sees the `query` argument:

```elixir
defmodule MyApp.Tools.SearchHelpCenter do
  use BeamWeaver.Tool

  alias BeamWeaver.Retriever

  name "search_help_center"
  description "Search Acme's help center for policies on refunds, shipping and returns."

  injected :context, :context

  schema do
    field :query, :string, description: "What the customer wants to know"
  end

  @impl true
  def invoke(_tool, %{"query" => query, context: %{help_center: retriever}}, _opts) do
    with {:ok, docs} <- Retriever.retrieve(retriever, query) do
      {:ok, Enum.map_join(docs, "\n\n", &"[#{&1.metadata["source"]}] #{&1.content}")}
    end
  end
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("search_help_center", %{"query" => "refund timing"}),
      "Refunds reach your card within 5 business days."
    ]

  system_prompt "You are Acme's support agent. Search the help center before answering policy questions."
  tools [MyApp.Tools.SearchHelpCenter]
end

{:ok, result} =
  MyApp.SupportAgent.invoke(%{messages: ["How long do refunds take?"]},
    context: %{help_center: retriever}
  )

Enum.map(result.messages, & &1.role)
#=> [:user, :assistant, :tool, :assistant]
```

The tool message holds the two passages the retriever found, each with its
source, and the model answers from them. The scripted model asks for the
search here; a real model writes its own queries and may search several times
before it answers. To build such a tool from a retriever at runtime, see
`BeamWeaver.Retriever.as_tool/2`; with `response_format: :content_and_artifact`,
the agent also keeps the documents it found in the tool message's
`metadata.artifact`.

## Retrieve first, or let the agent search

The search tool is one way to use retrieval. The other is to search first,
always, and put the results in the prompt of a single model call:

```elixir
defmodule MyApp.HelpCenterAnswer do
  alias BeamWeaver.Core.{ChatModel, Message}
  alias BeamWeaver.Retriever

  def answer(model, retriever, question) do
    with {:ok, docs} <- Retriever.retrieve(retriever, question),
         articles = Enum.map_join(docs, "\n\n", & &1.content),
         {:ok, reply} <-
           ChatModel.invoke(model, [
             Message.system("Answer only from these help center articles:\n\n" <> articles),
             Message.user(question)
           ]) do
      {:ok, Message.text(reply)}
    end
  end
end

model = Models.init_chat_model!("fake:chat", responses: ["Refunds take 5 business days."])
MyApp.HelpCenterAnswer.answer(model, retriever, "How long do refunds take?")
#=> {:ok, "Refunds take 5 business days."}
```

| | Retrieve, then answer | The agent searches |
| --- | --- | --- |
| Who searches | Your code, with the user's question | The model, with queries it writes |
| Model calls | One | Two or more |
| Use it when | Every question needs the documents, and cost and latency must be predictable | Only some questions need them, one search may not be enough, or the agent also has other tools |

To check the results before answering, rewrite a vague question, or search
again when nothing relevant came back, make each step a node of a
[graph](graphs.md).

## Reference

- [`BeamWeaver.Core.Document`](https://hexdocs.pm/beam_weaver/BeamWeaver.Core.Document.html): a text and its metadata
- [`BeamWeaver.TextSplitter`](https://hexdocs.pm/beam_weaver/BeamWeaver.TextSplitter.html): splitting text and documents into chunks
- [`BeamWeaver.Models`](https://hexdocs.pm/beam_weaver/BeamWeaver.Models.html): building embedding and chat models
- [`BeamWeaver.Core.EmbeddingModel`](https://hexdocs.pm/beam_weaver/BeamWeaver.Core.EmbeddingModel.html): embedding calls, and the behaviour for your own models
- [`BeamWeaver.Models.FakeEmbeddingModel`](https://hexdocs.pm/beam_weaver/BeamWeaver.Models.FakeEmbeddingModel.html): deterministic embeddings for tests
- [`BeamWeaver.VectorStore`](https://hexdocs.pm/beam_weaver/BeamWeaver.VectorStore.html): adding, searching and deleting documents
- [`BeamWeaver.VectorStore.ETS`](https://hexdocs.pm/beam_weaver/BeamWeaver.VectorStore.ETS.html): in-memory vector store
- [`BeamWeaver.VectorStore.EctoPostgres`](https://hexdocs.pm/beam_weaver/BeamWeaver.VectorStore.EctoPostgres.html): Postgres and pgvector vector store
- [`BeamWeaver.Retriever`](https://hexdocs.pm/beam_weaver/BeamWeaver.Retriever.html): retrieving, and the behaviour for your own retrievers
- [`BeamWeaver.RetrievalPolicy`](https://hexdocs.pm/beam_weaver/BeamWeaver.RetrievalPolicy.html): the options `as_retriever/2` accepts
- [`BeamWeaver.Migrations`](https://hexdocs.pm/beam_weaver/BeamWeaver.Migrations.html): creating the Postgres tables
