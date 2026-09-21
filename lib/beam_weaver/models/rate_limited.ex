defmodule BeamWeaver.Models.RateLimited do
  @moduledoc false

  @behaviour BeamWeaver.Core.ChatModel
  @behaviour BeamWeaver.Core.DecisionModel

  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Error
  alias BeamWeaver.RateLimiter
  alias BeamWeaver.RateLimitPolicy

  defstruct [:model, :policy]

  @impl true
  def decision_model?(wrapper), do: BeamWeaver.Core.DecisionModel.model?(wrapper.model)

  @impl true
  def evaluate(wrapper, input, opts) do
    with :ok <- acquire(wrapper, opts),
         do: BeamWeaver.Core.DecisionModel.invoke(wrapper.model, input, opts)
  end

  @impl true
  def invoke(wrapper, input, opts) when is_map(input), do: evaluate(wrapper, input, opts)

  def invoke(%__MODULE__{} = wrapper, messages, opts) do
    with :ok <- acquire(wrapper, opts) do
      ChatModel.invoke(wrapper.model, messages, opts)
    end
  end

  @impl true
  def stream(wrapper, input, opts) when is_map(input) do
    with {:ok, response} <- evaluate(wrapper, input, opts), do: {:ok, [response]}
  end

  def stream(%__MODULE__{} = wrapper, messages, opts) do
    with :ok <- acquire(wrapper, opts) do
      ChatModel.stream(wrapper.model, messages, opts)
    end
  end

  defp acquire(%__MODULE__{policy: %RateLimitPolicy{} = policy}, opts) do
    limiter = Keyword.get(opts, :rate_limiter, policy.limiter)

    if is_nil(limiter) do
      {:error, Error.new(:rate_limiter_required, "rate-limited model requires a limiter")}
    else
      do_acquire(limiter, policy)
    end
  end

  defp do_acquire(%{__struct__: module} = limiter, policy) do
    if function_exported?(module, :acquire, 3) do
      module.acquire(limiter, policy.amount, timeout: policy.timeout, key: policy.key)
    else
      {:error,
       Error.new(:invalid_rate_limiter, "custom rate limiter must implement acquire/3", %{
         module: module
       })}
    end
  end

  defp do_acquire(limiter, policy) do
    RateLimiter.acquire(limiter, policy.amount, timeout: policy.timeout, key: policy.key)
  end
end
