defmodule BeamWeaver.TextSplitter do
  @moduledoc """
  Text splitter facade using explicit Elixir structs.

  The facade keeps construction ergonomic while each splitter is a normal
  behaviour-backed struct. Each splitter carries its own options, including its
  tokenizer (see `from_tokenizer/2`); there are no global tokenizer settings.
  """

  alias BeamWeaver.TextSplitter.Documents
  alias BeamWeaver.TextSplitter.Language
  alias BeamWeaver.TextSplitter.RecursiveJSON
  alias BeamWeaver.TextSplitter.Shared

  @callback split_text(term(), String.t()) :: [String.t()]

  defstruct Shared.common_fields()

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

  def from_language(language, opts \\ []), do: recursive_character_from_language(language, opts)

  def recursive_character_from_language(language, opts \\ []) do
    opts
    |> Keyword.put(:separators, get_separators_for_language(language))
    |> Keyword.put_new(:separator_regex?, true)
    |> Keyword.put_new(:keep_separator, true)
    |> recursive_character()
  end

  def get_separators_for_language(language), do: Language.separators(language)

  def from_tokenizer(tokenizer, opts \\ []), do: token(Keyword.put(opts, :tokenizer, tokenizer))

  def split_text(%__MODULE__{} = splitter, text) when is_binary(text),
    do: Shared.split_text(splitter, text)

  def split_text(%module{} = splitter, text) when is_binary(text),
    do: module.split_text(splitter, text)

  def split_json(%RecursiveJSON{} = splitter, json_data, opts \\ []),
    do: RecursiveJSON.split_json(splitter, json_data, opts)

  def split_json_text(%RecursiveJSON{} = splitter, json_data, opts \\ []),
    do: RecursiveJSON.split_json_text(splitter, json_data, opts)

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
