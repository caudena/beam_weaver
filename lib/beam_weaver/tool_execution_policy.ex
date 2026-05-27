defmodule BeamWeaver.ToolExecutionPolicy do
  @moduledoc """
  Policy for tool execution boundaries.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.ExecutionPolicy

  defstruct execution: %ExecutionPolicy{},
            handle_errors: true,
            rate_limiter: nil,
            metadata: %{}

  @type t :: %__MODULE__{
          execution: ExecutionPolicy.t(),
          handle_errors: boolean() | atom() | [atom()] | String.t() | function(),
          rate_limiter: term(),
          metadata: map()
        }

  def new(opts \\ [])
  def new(%__MODULE__{} = policy), do: validate(policy)
  def new(opts) when is_list(opts), do: opts |> Map.new() |> new()

  def new(opts) when is_map(opts) do
    with {:ok, execution} <- ExecutionPolicy.new(Map.get(opts, :execution, execution_opts(opts))) do
      %__MODULE__{
        execution: execution,
        handle_errors: Map.get(opts, :handle_errors, true),
        rate_limiter: Map.get(opts, :rate_limiter),
        metadata: Map.get(opts, :metadata, %{})
      }
      |> validate()
    end
  end

  def new!(opts \\ []) do
    case new(opts) do
      {:ok, policy} -> policy
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  def validate(%__MODULE__{} = policy) do
    if is_map(policy.metadata) do
      {:ok, policy}
    else
      {:error, Error.new(:invalid_tool_execution_policy, "metadata must be a map")}
    end
  end

  defp execution_opts(opts), do: Map.take(opts, [:timeout, :max_concurrency, :metadata])
end
