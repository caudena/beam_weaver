defmodule BeamWeaver.RateLimitPolicy do
  @moduledoc ~S"""
  Admission settings for a model wrapper or service operation.

  limiter is a live bucket/name or compatible adapter; amount is a positive
  request weight (default 1), key selects an adapter-defined quota and timeout
  bounds waiting in milliseconds (default 5,000). Construction validates policy
  shape; it does not start the limiter or establish a distributed quota.
  See [Rate Limiting](rate_limiting.md).
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Policy

  defstruct limiter: nil,
            amount: 1,
            key: nil,
            timeout: 5_000

  @fields [:limiter, :amount, :key, :timeout]

  @type t :: %__MODULE__{
          limiter: term(),
          amount: pos_integer(),
          key: term(),
          timeout: timeout()
        }

  def new(opts \\ []), do: Policy.build(__MODULE__, opts, @fields, &validate/1)

  def new!(opts \\ []), do: opts |> new() |> Policy.bang()

  def validate(%__MODULE__{} = policy) do
    cond do
      not is_integer(policy.amount) or policy.amount < 1 ->
        {:error, Error.new(:invalid_rate_limit_policy, "amount must be a positive integer")}

      not Policy.valid_timeout?(policy.timeout) ->
        {:error,
         Error.new(
           :invalid_rate_limit_policy,
           "timeout must be nil, :infinity, or a non-negative integer"
         )}

      true ->
        {:ok, policy}
    end
  end
end
