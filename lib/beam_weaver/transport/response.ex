defmodule BeamWeaver.Transport.Response do
  @moduledoc """
  Transport response returned by live and replay providers.
  """

  defstruct status: nil,
            headers: [],
            body: "",
            metadata: %{}

  @type t :: %__MODULE__{
          status: non_neg_integer() | nil,
          headers: [{String.t(), String.t()}],
          body: binary() | term(),
          metadata: map()
        }

  @doc """
  Builds a response with normalized headers.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      status: Keyword.get(opts, :status),
      headers: BeamWeaver.Transport.Request.normalize_headers(Keyword.get(opts, :headers, [])),
      body: Keyword.get(opts, :body, ""),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end
end
