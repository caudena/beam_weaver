defmodule BeamWeaver.Core.Document do
  @moduledoc """
  Text document used by retrieval, indexing, and data processing flows.
  """

  alias BeamWeaver.Core.Error

  @enforce_keys [:content]
  defstruct [:id, :content, metadata: %{}, type: "Document"]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          content: String.t(),
          metadata: map(),
          type: String.t()
        }

  @doc """
  Builds a document with validation.
  """
  @spec new(String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(content, opts \\ [])

  def new(content, opts) when is_binary(content) do
    metadata = Keyword.get(opts, :metadata, %{})

    if is_map(metadata) do
      {:ok, %__MODULE__{id: id(Keyword.get(opts, :id)), content: content, metadata: metadata}}
    else
      {:error, Error.new(:invalid_metadata, "document metadata must be a map")}
    end
  end

  def new(_content, _opts) do
    {:error, Error.new(:invalid_content, "document content must be a string")}
  end

  @doc """
  Builds a document and raises on invalid input.
  """
  @spec new!(String.t(), keyword()) :: t()
  def new!(content, opts \\ []) do
    case new(content, opts) do
      {:ok, document} -> document
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @doc """
  Validates a document shape.
  """
  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{content: content, metadata: metadata})
      when is_binary(content) and is_map(metadata),
      do: :ok

  def validate(_term),
    do: {:error, Error.new(:invalid_document, "expected a BeamWeaver document")}

  defp id(nil), do: nil
  defp id(value), do: to_string(value)

  @doc """
  LangChain serialization namespace retained for document interop.
  """
  @spec lc_namespace() :: [String.t()]
  def lc_namespace, do: ["langchain", "schema", "document"]

  @spec serializable?() :: true
  def serializable?, do: true

  @doc """
  Returns a compact prompt-facing string that omits internal fields like `id`.
  """
  @spec langchain_string(t()) :: String.t()
  def langchain_string(%__MODULE__{content: content, metadata: metadata}) when metadata == %{} do
    "page_content=#{quote_content(content)}"
  end

  def langchain_string(%__MODULE__{content: content, metadata: metadata}) do
    "page_content=#{quote_content(content)} metadata=#{inspect(metadata)}"
  end

  defp quote_content(content) do
    "'" <> String.replace(content, "'", "\\'") <> "'"
  end
end

defimpl String.Chars, for: BeamWeaver.Core.Document do
  def to_string(document), do: BeamWeaver.Core.Document.langchain_string(document)
end
