defmodule BeamWeaver.TimeoutPolicy do
  @moduledoc """
  Native timeout policy for graph node/task attempts.

  BeamWeaver stores timeout durations as milliseconds to match OTP APIs. Float
  inputs are treated as seconds for LangGraph-style interop.
  """

  alias BeamWeaver.Core.Error

  defstruct run_timeout: nil,
            idle_timeout: nil,
            refresh_on: :auto

  @type refresh_on :: :auto | :heartbeat

  @type t :: %__MODULE__{
          run_timeout: pos_integer() | nil,
          idle_timeout: pos_integer() | nil,
          refresh_on: refresh_on()
        }

  @spec new(keyword() | map() | t()) :: {:ok, t() | nil} | {:error, Error.t()}
  def new(value), do: coerce(value)

  @spec new!(keyword() | map() | t()) :: t() | nil
  def new!(value) do
    case new(value) do
      {:ok, policy} -> policy
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec coerce(float() | non_neg_integer() | keyword() | map() | t() | nil) ::
          {:ok, t() | nil} | {:error, Error.t()}
  def coerce(nil), do: {:ok, nil}

  def coerce(%__MODULE__{} = policy) do
    cond do
      policy.refresh_on not in [:auto, :heartbeat] ->
        invalid("refresh_on must be :auto or :heartbeat", %{refresh_on: policy.refresh_on})

      not positive_timeout_or_nil?(policy.run_timeout) ->
        invalid("run_timeout must be greater than 0", %{run_timeout: policy.run_timeout})

      not positive_timeout_or_nil?(policy.idle_timeout) ->
        invalid("idle_timeout must be greater than 0", %{idle_timeout: policy.idle_timeout})

      is_nil(policy.run_timeout) and is_nil(policy.idle_timeout) ->
        {:ok, nil}

      true ->
        {:ok, policy}
    end
  end

  def coerce(value) when is_float(value) or is_integer(value) do
    value
    |> duration_to_ms()
    |> then(&coerce(%__MODULE__{run_timeout: &1}))
  end

  def coerce(opts) when is_list(opts), do: opts |> Map.new() |> coerce()

  def coerce(map) when is_map(map) do
    policy = %__MODULE__{
      run_timeout: map |> get(:run_timeout) |> duration_to_ms(),
      idle_timeout: map |> get(:idle_timeout) |> duration_to_ms(),
      refresh_on: map |> get(:refresh_on, :auto) |> normalize_refresh_on()
    }

    coerce(policy)
  end

  def coerce(value),
    do:
      invalid("timeout policy must be nil, a duration, map, keyword list, or TimeoutPolicy", %{
        value: inspect(value)
      })

  @doc """
  Returns the effective BEAM task timeout for a policy.

  LangGraph exposes separate run and idle budgets. BeamWeaver executes graph
  nodes as supervised BEAM tasks, so the public graph boundary uses the earliest
  configured budget as the hard task timeout. Step and graph run budgets remain
  separate `Compiled` execution options.
  """
  @spec effective_timeout(t() | keyword() | map() | number() | nil) ::
          {:ok, pos_integer() | nil} | {:error, Error.t()}
  def effective_timeout(value) do
    with {:ok, policy} <- coerce(value) do
      {:ok, effective_timeout_from_policy(policy)}
    end
  end

  @spec effective_timeout!(t() | keyword() | map() | number() | nil) :: pos_integer() | nil
  def effective_timeout!(value) do
    case effective_timeout(value) do
      {:ok, timeout} -> timeout
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp effective_timeout_from_policy(nil), do: nil

  defp effective_timeout_from_policy(%__MODULE__{run_timeout: nil, idle_timeout: idle}),
    do: idle

  defp effective_timeout_from_policy(%__MODULE__{run_timeout: run, idle_timeout: nil}),
    do: run

  defp effective_timeout_from_policy(%__MODULE__{run_timeout: run, idle_timeout: idle}),
    do: min(run, idle)

  defp get(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp duration_to_ms(nil), do: nil
  defp duration_to_ms(value) when is_float(value), do: round(value * 1_000)
  defp duration_to_ms(value) when is_integer(value), do: value
  defp duration_to_ms(_value), do: -1

  defp normalize_refresh_on("auto"), do: :auto
  defp normalize_refresh_on("heartbeat"), do: :heartbeat
  defp normalize_refresh_on(value), do: value

  defp positive_timeout_or_nil?(nil), do: true
  defp positive_timeout_or_nil?(value), do: is_integer(value) and value > 0

  defp invalid(message, details),
    do: {:error, Error.new(:invalid_timeout_policy, message, details)}
end
