defmodule BeamWeaver.Agent.Subagent.Host.Proposal do
  @moduledoc "Closed, non-authorizing child proposal passed to an application host."

  @enforce_keys [:type, :task, :mode, :correlation_id]
  defstruct schema_version: 1, type: nil, task: nil, mode: nil, correlation_id: nil

  @max_type_bytes 128
  @max_task_bytes 64 * 1024
  @max_correlation_bytes 256

  @type t :: %__MODULE__{
          schema_version: 1,
          type: String.t(),
          task: String.t(),
          mode: :foreground | :background,
          correlation_id: String.t()
        }

  @doc false
  def valid?(%__MODULE__{} = proposal) do
    proposal.schema_version == 1 and proposal.mode in [:foreground, :background] and
      bounded?(proposal.type, @max_type_bytes) and bounded?(proposal.task, @max_task_bytes) and
      bounded?(proposal.correlation_id, @max_correlation_bytes)
  end

  defp bounded?(value, maximum),
    do: is_binary(value) and byte_size(value) > 0 and byte_size(value) <= maximum
end

defmodule BeamWeaver.Agent.Subagent.Host.Handle do
  @moduledoc "Opaque application-owned child handle."

  @enforce_keys [:id, :mode]
  defstruct schema_version: 1, id: nil, mode: nil

  @type t :: %__MODULE__{schema_version: 1, id: String.t(), mode: :foreground | :background}

  @doc false
  def valid?(%__MODULE__{schema_version: 1, id: id, mode: mode}),
    do: is_binary(id) and id != "" and mode in [:foreground, :background]
end

defmodule BeamWeaver.Agent.Subagent.Host.Result do
  @moduledoc "Bounded child result projection returned by an application host."

  @outcomes [:completed, :failed, :cancelled, :blocked_capability, :needs_parent_input]
  @max_content_bytes 64 * 1024
  @max_evidence_refs 32

  @enforce_keys [:handle_id, :outcome]
  defstruct schema_version: 1, handle_id: nil, outcome: nil, content: nil, evidence_refs: []

  @type t :: %__MODULE__{
          schema_version: 1,
          handle_id: String.t(),
          outcome: atom(),
          content: String.t() | nil,
          evidence_refs: [String.t()]
        }

  @doc false
  def valid?(%__MODULE__{} = result, %BeamWeaver.Agent.Subagent.Host.Handle{} = handle) do
    result.schema_version == 1 and result.handle_id == handle.id and result.outcome in @outcomes and
      (is_nil(result.content) or is_binary(result.content)) and
      (is_nil(result.content) or byte_size(result.content) <= @max_content_bytes) and
      is_list(result.evidence_refs) and length(result.evidence_refs) <= @max_evidence_refs and
      Enum.all?(result.evidence_refs, &(is_binary(&1) and &1 != "")) and
      not (handle.mode == :background and result.outcome == :needs_parent_input)
  end
end

defmodule BeamWeaver.Agent.Subagent.Host do
  @moduledoc """
  Policy-neutral boundary for application-owned child admission and results.

  The host owns persistence, scheduling, authorization, and recovery. BeamWeaver
  passes only the closed proposal below and never treats a missing result as
  success.
  """

  alias BeamWeaver.Adapter.Dispatch
  alias BeamWeaver.Agent.Subagent.Host.{Handle, Proposal, Result}
  alias BeamWeaver.Core.Error

  @callback admit_child(struct(), Proposal.t(), term()) ::
              {:ok, Handle.t()} | {:error, term()}
  @callback child_result(struct(), Handle.t(), term()) ::
              {:ok, Result.t()} | {:pending, Handle.t()} | {:error, term()}

  @spec admit(struct(), Proposal.t(), term()) :: {:ok, Handle.t()} | {:error, term()}
  def admit(host, %Proposal{} = proposal, context) do
    if Proposal.valid?(proposal) do
      host
      |> Dispatch.call(:admit_child, [proposal, context], error_type: :invalid_subagent_host)
      |> normalize_handle()
    else
      invalid("invalid child proposal")
    end
  end

  @spec result(struct(), Handle.t(), term()) ::
          {:ok, Result.t()} | {:pending, Handle.t()} | {:error, term()}
  def result(host, %Handle{} = handle, context) do
    host
    |> Dispatch.call(:child_result, [handle, context], error_type: :invalid_subagent_host)
    |> normalize_result(handle)
  end

  defp normalize_handle({:ok, %Handle{} = handle}) do
    if Handle.valid?(handle), do: {:ok, handle}, else: invalid("host returned an invalid child handle")
  end

  defp normalize_handle({:error, _reason} = error), do: error
  defp normalize_handle(_other), do: invalid("host returned an invalid admission result")

  defp normalize_result({:ok, %Result{} = result}, handle) do
    if Result.valid?(result, handle), do: {:ok, result}, else: invalid("host returned an invalid child result")
  end

  defp normalize_result({:pending, %Handle{} = current}, handle) do
    if handle.mode == :background and current == handle and Handle.valid?(current) do
      {:pending, current}
    else
      invalid("only the identical background handle may remain pending")
    end
  end

  defp normalize_result({:error, _reason} = error, _handle), do: error
  defp normalize_result(_other, _handle), do: invalid("host returned an invalid result response")

  defp invalid(message), do: {:error, Error.new(:invalid_subagent_host, message)}
end
