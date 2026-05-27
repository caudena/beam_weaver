defmodule BeamWeaver.Core.ToolResult do
  @moduledoc """
  Structured result returned by tools when content and metadata need to differ.

  `content` becomes the tool message content. `artifact` stays out of model-visible
  text and is stored in message metadata for application use.
  """

  @enforce_keys [:content]
  defstruct [:content, :artifact, status: :success, metadata: %{}]

  @type status :: :success | :error | String.t()

  @type t :: %__MODULE__{
          content: term(),
          artifact: term(),
          status: status(),
          metadata: map()
        }

  @spec success(term(), keyword()) :: t()
  def success(content, opts \\ []) do
    %__MODULE__{
      content: content,
      artifact: Keyword.get(opts, :artifact),
      status: Keyword.get(opts, :status, :success),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @spec error(term(), keyword()) :: t()
  def error(content, opts \\ []) do
    %__MODULE__{
      content: content,
      artifact: Keyword.get(opts, :artifact),
      status: Keyword.get(opts, :status, :error),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end
end
