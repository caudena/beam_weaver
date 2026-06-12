defmodule BeamWeaver.ExecutionPolicy do
  @moduledoc """
  Shared execution policy for bounded runtime work.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Policy

  defstruct timeout: 5_000,
            max_concurrency: nil,
            metadata: %{}

  @fields [:timeout, :max_concurrency, :metadata]

  @type t :: %__MODULE__{
          timeout: timeout(),
          max_concurrency: pos_integer() | nil,
          metadata: map()
        }

  @spec new(keyword() | map() | t()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = policy), do: validate(policy)

  def new(opts),
    do: Policy.build(__MODULE__, opts, @fields, &validate/1, normalize: &normalize_value/2)

  @spec new!(keyword() | map() | t()) :: t()
  def new!(opts), do: opts |> new() |> Policy.bang()

  def validate(%__MODULE__{} = policy) do
    cond do
      not Policy.valid_timeout?(policy.timeout) ->
        invalid("timeout must be nil, :infinity, or a non-negative integer", %{
          timeout: policy.timeout
        })

      not (is_nil(policy.max_concurrency) or
               (is_integer(policy.max_concurrency) and policy.max_concurrency > 0)) ->
        invalid("max_concurrency must be nil or a positive integer", %{
          max_concurrency: policy.max_concurrency
        })

      not is_map(policy.metadata) ->
        invalid("metadata must be a map", %{metadata: inspect(policy.metadata)})

      true ->
        {:ok, policy}
    end
  end

  defp normalize_value(:timeout, value), do: Policy.duration_to_ms(value)
  defp normalize_value(_key, value), do: value

  defp invalid(message, details),
    do: {:error, Error.new(:invalid_execution_policy, message, details)}
end
