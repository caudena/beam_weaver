defmodule BeamWeaver.Core.Document do
  @moduledoc """
  Text document used by retrieval, indexing, and data processing flows.
  """

  alias BeamWeaver.Core.Error

  @enforce_keys [:content]
  defstruct [:id, :content, metadata: %{}]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          content: String.t(),
          metadata: map()
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
  Builds a document from a document, a string, or a map with `:content` and
  optional `:id` and `:metadata`.
  """
  @spec from(t() | String.t() | map()) :: {:ok, t()} | {:error, Error.t()}
  def from(%__MODULE__{} = document) do
    with :ok <- validate(document), do: {:ok, document}
  end

  def from(content) when is_binary(content), do: new(content)

  def from(%{content: content} = map),
    do: new(content, id: Map.get(map, :id), metadata: Map.get(map, :metadata, %{}))

  def from(_value),
    do: {:error, Error.new(:invalid_document, "expected a document, a string, or a map with :content")}

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
end
