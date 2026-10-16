defmodule BeamWeaver.TextSplitter do
  @moduledoc """
  Text splitter facade using explicit Elixir structs.

  The facade keeps construction ergonomic while each splitter is a normal
  behaviour-backed struct. Each splitter carries its own options, including its
  tokenizer (see `from_tokenizer/2`); there are no global tokenizer settings.
  """

  alias BeamWeaver.TextSplitter.Documents
  alias BeamWeaver.TextSplitter.Language
  alias BeamWeaver.TextSplitter.Shared

  @callback split_text(term(), String.t()) :: [String.t()]

  defstruct chunk_size: 1_000,
            chunk_overlap: 200,
            separators: ["\n\n", "\n", " ", ""],
            keep_separator: false,
            strip_whitespace: true,
            add_start_index: false,
            length_function: nil,
            separator_regex?: false

  def character(opts \\ []), do: BeamWeaver.TextSplitter.Character.new(opts)
  def recursive_character(opts \\ []), do: BeamWeaver.TextSplitter.RecursiveCharacter.new(opts)
  def markdown(opts \\ []), do: BeamWeaver.TextSplitter.Markdown.new(opts)
  def markdown_headers(opts \\ []), do: BeamWeaver.TextSplitter.MarkdownHeaders.new(opts)
  def markdown_syntax(opts \\ []), do: BeamWeaver.TextSplitter.MarkdownSyntax.new(opts)
  def html(opts \\ []), do: BeamWeaver.TextSplitter.HTML.new(opts)
  def html_headers(opts \\ []), do: BeamWeaver.TextSplitter.HTMLHeaders.new(opts)
  def html_semantic(opts \\ []), do: BeamWeaver.TextSplitter.HTMLSemantic.new(opts)
  def json(opts \\ []), do: recursive_json(opts)
  def recursive_json(opts \\ []), do: BeamWeaver.TextSplitter.RecursiveJSON.new(opts)
  def latex(opts \\ []), do: BeamWeaver.TextSplitter.LaTeX.new(opts)
  def code(opts \\ []), do: BeamWeaver.TextSplitter.Code.new(opts)
  def python(opts \\ []), do: BeamWeaver.TextSplitter.Python.new(opts)
  def jsx(opts \\ []), do: BeamWeaver.TextSplitter.JSX.new(opts)
  def token(opts \\ []), do: BeamWeaver.TextSplitter.Token.new(opts)

  def from_language(language, opts \\ []) do
    recursive_character_from_language(language, opts)
  end

  def recursive_character_from_language(language, opts \\ []) do
    language
    |> get_separators_for_language()
    |> then(
      &recursive_character(
        opts
        |> Keyword.put(:separators, &1)
        |> Keyword.put_new(:separator_regex?, true)
        |> Keyword.put_new(:keep_separator, true)
      )
    )
  end

  def get_separators_for_language(language) do
    Language.separators(language)
  end

  def from_tokenizer(tokenizer, opts \\ []) do
    opts
    |> Keyword.put(:tokenizer, tokenizer)
    |> token()
  end

  def split_text(%__MODULE__{} = splitter, text) when is_binary(text),
    do: Shared.split_text(splitter, text)

  def split_text(%module{} = splitter, text) when is_binary(text),
    do: module.split_text(splitter, text)

  def split_json(%BeamWeaver.TextSplitter.RecursiveJSON{} = splitter, json_data, opts \\ []) do
    BeamWeaver.TextSplitter.RecursiveJSON.split_json(splitter, json_data, opts)
  end

  def split_json_text(%BeamWeaver.TextSplitter.RecursiveJSON{} = splitter, json_data, opts \\ []) do
    BeamWeaver.TextSplitter.RecursiveJSON.split_json_text(splitter, json_data, opts)
  end

  def create_json_documents(
        %BeamWeaver.TextSplitter.RecursiveJSON{} = splitter,
        json_values,
        opts \\ []
      ) do
    BeamWeaver.TextSplitter.RecursiveJSON.create_json_documents(splitter, json_values, opts)
  end

  @doc """
  Lazily splits one text or an enumerable of texts into text chunks.

  Splitting a single text still needs that text in memory, but an enumerable of
  documents is consumed lazily so callers can wire loaders to splitters without
  materializing every chunk first.
  """
  defdelegate stream_text(splitter, texts), to: Documents

  @doc """
  Splits a collection of documents into chunked documents.

  Chunks keep their document's metadata. The chunks of a document with an id
  get ids made from it (`"refunds:0"`, `"refunds:1"`, ...) and the document's
  id as `"parent_id"` in their metadata, which `BeamWeaver.Indexing.index/3`
  uses as their source when they have no `"source"`.
  """
  defdelegate split_documents(splitter, documents), to: Documents

  @doc "Transforms a document collection into split documents."
  defdelegate transform_documents(splitter, documents, opts \\ []), to: Documents

  @doc """
  Reads one file and lazily splits it as a single document.

  This is the native file boundary for header and text splitters. Callers keep
  control of path policy before invoking it.
  """
  defdelegate split_file(splitter, path, opts \\ []), to: Documents

  @doc """
  Fetches one URL and lazily splits the response body as a single document,
  with the URL as its `:source` metadata.

  The URL must pass a `BeamWeaver.Transport.URLPolicy` first, so a URL from a
  user or a model can't reach your internal network. By default only `https`
  URLs to public addresses pass: private, loopback, link-local and cloud
  metadata addresses are refused, also when a host name resolves to one. The
  request connects to the address that passed the check, and each redirect
  must pass the same policy. A refused URL returns
  `{:error, %BeamWeaver.Core.Error{type: :unsafe_url}}`.

  Options:

    * `:url_policy` - policy options as a keyword list, such as
      `allowed_hosts:` or `follow_redirects?: false` (redirects are followed
      by default), or a policy struct, used as it is. Either way, host names
      are resolved and checked.
    * `:metadata` - metadata for the document; `:source` defaults to the URL.
    * `:fetcher` - a one-argument function returning `{:ok, body}` or
      `{:error, reason}`, used instead of the HTTP request, for example in
      tests. It gets the URL only after the policy's checks that need no DNS
      lookup, and it is responsible for its own connection.
  """
  defdelegate split_url(splitter, url, opts \\ []), to: Documents

  @doc "Creates documents from text values and splits them."
  defdelegate create_documents(splitter, texts, opts \\ []), to: Documents

  @doc "Validates a splitter configuration."
  defdelegate validate(splitter), to: Documents
end
