defmodule BeamWeaver.TextSplitter do
  @moduledoc ~S"""
  Construct explicit text splitters and turn source material into retrieval chunks.

  Character splitters use size/overlap measured by their length function; token
  splitters use an explicitly supplied or configured tokenizer. Header/syntax
  splitters preserve selected document boundaries. Choose a representation that
  keeps the source context required to answer your application's questions.

  split_documents and stream_text expose lazy collections; consume them to do
  the work. Document metadata and parent identity are retained. URL loading
  has a separate policy/transport boundary, while file paths remain the caller's
  responsibility. See [Retrieval](retrieval.md#text-splitters).
  """

  alias BeamWeaver.TextSplitter.Documents
  alias BeamWeaver.TextSplitter.Language
  alias BeamWeaver.TextSplitter.RecursiveJSON
  alias BeamWeaver.TextSplitter.Shared

  @doc """
  Splits one text into an ordered list of text chunks according to the adapter configuration.
  """
  @callback split_text(term(), String.t()) :: [String.t()]

  defstruct Shared.common_fields()

  @doc """
  Constructs a separator-based character splitter with size/overlap options.
  """
  def character(opts \\ []), do: BeamWeaver.TextSplitter.Character.new(opts)

  @doc """
  Constructs a prose splitter that tries progressively finer separators.
  """
  def recursive_character(opts \\ []), do: BeamWeaver.TextSplitter.RecursiveCharacter.new(opts)

  @doc """
  Constructs a Markdown-aware recursive splitter.
  """
  def markdown(opts \\ []), do: BeamWeaver.TextSplitter.Markdown.new(opts)

  @doc """
  Constructs a heading-based Markdown splitter with heading metadata.
  """
  def markdown_headers(opts \\ []), do: BeamWeaver.TextSplitter.MarkdownHeaders.new(opts)

  @doc """
  Constructs a splitter that respects Markdown syntax structure.
  """
  def markdown_syntax(opts \\ []), do: BeamWeaver.TextSplitter.MarkdownSyntax.new(opts)

  @doc """
  Constructs an HTML-oriented text splitter.
  """
  def html(opts \\ []), do: BeamWeaver.TextSplitter.HTML.new(opts)

  @doc """
  Constructs an HTML heading splitter that retains heading metadata.
  """
  def html_headers(opts \\ []), do: BeamWeaver.TextSplitter.HTMLHeaders.new(opts)

  @doc """
  Constructs an HTML splitter that preserves configured semantic elements.
  """
  def html_semantic(opts \\ []), do: BeamWeaver.TextSplitter.HTMLSemantic.new(opts)

  @doc """
  Alias for recursive_json/1.
  """
  def json(opts \\ []), do: recursive_json(opts)

  @doc """
  Constructs a splitter for JSON values; use the JSON-specific split functions.
  """
  def recursive_json(opts \\ []), do: BeamWeaver.TextSplitter.RecursiveJSON.new(opts)

  @doc """
  Constructs a LaTeX-aware recursive splitter.
  """
  def latex(opts \\ []), do: BeamWeaver.TextSplitter.LaTeX.new(opts)

  @doc """
  Constructs a source-code splitter using configured language/separator options.
  """
  def code(opts \\ []), do: BeamWeaver.TextSplitter.Code.new(opts)

  @doc """
  Constructs a Python-aware source splitter.
  """
  def python(opts \\ []), do: BeamWeaver.TextSplitter.Python.new(opts)

  @doc """
  Constructs a JSX-aware source splitter.
  """
  def jsx(opts \\ []), do: BeamWeaver.TextSplitter.JSX.new(opts)

  @doc """
  Constructs a token-based splitter; chunk size/overlap are token counts.
  """
  def token(opts \\ []), do: BeamWeaver.TextSplitter.Token.new(opts)

  @doc """
  Constructs a recursive splitter using the language separator set.
  """
  def from_language(language, opts \\ []), do: recursive_character_from_language(language, opts)

  @doc """
  Applies language separators while retaining definition boundaries.
  """
  def recursive_character_from_language(language, opts \\ []) do
    opts
    |> Keyword.put(:separators, get_separators_for_language(language))
    |> Keyword.put_new(:separator_regex?, true)
    |> Keyword.put_new(:keep_separator, true)
    |> recursive_character()
  end

  @doc """
  Returns the separator set used for the named source language.
  """
  def get_separators_for_language(language), do: Language.separators(language)

  @doc """
  Constructs a token splitter with an explicit tokenizer dependency.
  """
  def from_tokenizer(tokenizer, opts \\ []), do: token(Keyword.put(opts, :tokenizer, tokenizer))

  @doc """
  Splits one text value into chunks through the configured splitter.
  """
  def split_text(%__MODULE__{} = splitter, text) when is_binary(text),
    do: Shared.split_text(splitter, text)

  def split_text(%module{} = splitter, text) when is_binary(text),
    do: module.split_text(splitter, text)

  @doc """
  Splits a JSON value into smaller JSON values.
  """
  def split_json(%RecursiveJSON{} = splitter, json_data, opts \\ []),
    do: RecursiveJSON.split_json(splitter, json_data, opts)

  @doc """
  Splits a JSON value and renders the resulting chunks as JSON text.
  """
  def split_json_text(%RecursiveJSON{} = splitter, json_data, opts \\ []),
    do: RecursiveJSON.split_json_text(splitter, json_data, opts)

  @doc """
  Wraps split JSON values as retrieval documents.
  """
  def create_json_documents(%RecursiveJSON{} = splitter, json_values, opts \\ []),
    do: RecursiveJSON.create_json_documents(splitter, json_values, opts)

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
  id as `"parent_id"` in their metadata.
  """
  defdelegate split_documents(splitter, documents), to: Documents

  @doc "Transforms a document collection into split documents."
  def transform_documents(splitter, documents, _opts \\ []), do: split_documents(splitter, documents)

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
