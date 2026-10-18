defmodule BeamWeaver.TimeoutPolicy do
  @moduledoc """
  Timeout policy for graph node/task attempts.

  BeamWeaver stores timeout durations as milliseconds to match OTP APIs.
  Integer inputs are milliseconds; float inputs are treated as seconds.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.MapAccess
  alias BeamWeaver.Options
  alias BeamWeaver.Policy

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
  def new!(value), do: value |> new() |> Policy.bang()

  @spec coerce(float() | non_neg_integer() | keyword() | map() | t() | nil) ::
          {:ok, t() | nil} | {:error, Error.t()}
  def coerce(nil), do: {:ok, nil}

  def coerce(%__MODULE__{} = policy) do
    cond do
      match?({:invalid, _message}, policy.refresh_on) ->
        invalid(elem(policy.refresh_on, 1), %{refresh_on: policy.refresh_on})

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

  def coerce(value) when is_float(value) or is_integer(value),
    do: coerce(%__MODULE__{run_timeout: duration_to_ms(value)})

  def coerce(opts) when is_list(opts), do: opts |> Map.new() |> coerce()

  def coerce(map) when is_map(map) do
    policy = %__MODULE__{
      run_timeout: map |> MapAccess.get(:run_timeout) |> duration_to_ms(),
      idle_timeout: map |> MapAccess.get(:idle_timeout) |> duration_to_ms(),
      refresh_on: map |> MapAccess.get(:refresh_on, :auto) |> normalize_refresh_on()
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

  A policy can set separate run and idle budgets. Graph nodes run as supervised
  BEAM tasks with a single hard timeout, so this returns the smaller of the
  configured budgets. Step and graph run budgets remain separate `Compiled`
  execution options.
  """
  @spec effective_timeout(t() | keyword() | map() | number() | nil) ::
          {:ok, pos_integer() | nil} | {:error, Error.t()}
  def effective_timeout(value) do
    with {:ok, policy} <- coerce(value) do
      {:ok, effective_timeout_from_policy(policy)}
    end
  end

  @spec effective_timeout!(t() | keyword() | map() | number() | nil) :: pos_integer() | nil
  def effective_timeout!(value), do: value |> effective_timeout() |> Policy.bang()

  defp effective_timeout_from_policy(nil), do: nil

  # A coerced policy sets at least one of the budgets.
  defp effective_timeout_from_policy(%__MODULE__{run_timeout: run, idle_timeout: idle}),
    do: Enum.min(Enum.reject([run, idle], &is_nil/1))

  defp duration_to_ms(nil), do: nil
  defp duration_to_ms(value) when is_float(value), do: round(value * 1_000)
  defp duration_to_ms(value) when is_integer(value), do: value
  defp duration_to_ms(_value), do: -1

  defp normalize_refresh_on(value) do
    case Options.atom_enum_error("refresh_on", value, [:auto, :heartbeat]) do
      :ok -> value
      {:error, message} -> {:invalid, message}
    end
  end

  defp positive_timeout_or_nil?(nil), do: true
  defp positive_timeout_or_nil?(value), do: is_integer(value) and value > 0

  defp invalid(message, details),
    do: {:error, Error.new(:invalid_timeout_policy, message, details)}
end
