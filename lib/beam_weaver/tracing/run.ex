defmodule BeamWeaver.Tracing.Run do
  @moduledoc """
  Local trace run recorded by BeamWeaver.
  """

  alias BeamWeaver.Core.ID

  @type id :: String.t()
  @type status :: :running | :ok | :error

  @enforce_keys [:id, :trace_id, :name, :kind, :status, :started_at]
  defstruct [
    :id,
    :trace_id,
    :parent_id,
    :name,
    :kind,
    :status,
    :started_at,
    :ended_at,
    tags: [],
    metadata: %{},
    inputs: nil,
    outputs: nil,
    usage: %{},
    error: nil
  ]

  @type t :: %__MODULE__{
          id: id(),
          trace_id: id(),
          parent_id: id() | nil,
          name: String.t(),
          kind: atom(),
          status: status(),
          started_at: DateTime.t(),
          ended_at: DateTime.t() | nil,
          tags: [String.t()],
          metadata: map(),
          inputs: term(),
          outputs: term(),
          usage: map(),
          error: term()
        }

  @doc """
  Builds a new running trace run.
  """
  @spec new(String.t() | atom(), keyword()) :: t()
  def new(name, opts \\ []) do
    id = Keyword.get_lazy(opts, :id, &new_id/0)
    trace_id = Keyword.get(opts, :trace_id) || id

    %__MODULE__{
      id: id,
      trace_id: trace_id,
      parent_id: Keyword.get(opts, :parent_id),
      name: to_string(name),
      kind: Keyword.get(opts, :kind, :operation),
      status: :running,
      started_at: Keyword.get_lazy(opts, :started_at, &DateTime.utc_now/0),
      tags: normalize_tags(Keyword.get(opts, :tags, [])),
      metadata: BeamWeaver.Tracing.Redactor.redact(Keyword.get(opts, :metadata, %{})),
      inputs: BeamWeaver.Tracing.Redactor.redact(Keyword.get(opts, :inputs)),
      usage: BeamWeaver.Tracing.Redactor.redact(Keyword.get(opts, :usage, %{}))
    }
  end

  defp new_id do
    ID.uuidv7()
  end

  defp normalize_tags(tags) do
    tags
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
  end
end
