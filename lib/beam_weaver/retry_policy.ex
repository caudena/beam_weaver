defmodule BeamWeaver.RetryPolicy do
  @moduledoc """
  Explicit retry policy shared by model, tool, graph, and provider code.

  The policy is pure data plus validation. Callers own the actual retry loop so
  they can keep cancellation, telemetry, and runtime context local to their
  execution boundary.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Policy

  defstruct max_attempts: 3,
            initial_delay: 0,
            max_delay: 5_000,
            backoff: 2.0,
            jitter: false,
            retry_on: :error,
            timeout: nil

  @fields MapSet.new([
            :max_attempts,
            :initial_delay,
            :max_delay,
            :backoff,
            :jitter,
            :retry_on,
            :timeout
          ])

  @type retry_on ::
          :error
          | :all
          | atom()
          | [atom()]
          | (Error.t() | term() -> boolean())
          | {module(), atom(), list()}

  @type t :: %__MODULE__{
          max_attempts: pos_integer(),
          initial_delay: non_neg_integer(),
          max_delay: non_neg_integer(),
          backoff: number(),
          jitter: boolean() | non_neg_integer(),
          retry_on: retry_on(),
          timeout: timeout()
        }

  @spec new(keyword() | map() | t()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = policy), do: validate(policy)

  def new(opts),
    do:
      Policy.build(__MODULE__, opts, @fields, &validate/1,
        unknown: :error,
        error_type: :invalid_retry_policy,
        unknown_message: "unknown retry policy option",
        normalize: &normalize_value/2
      )

  @spec new!(keyword() | map() | t()) :: t()
  def new!(opts \\ []), do: opts |> new() |> Policy.bang()

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = policy) do
    cond do
      not is_integer(policy.max_attempts) or policy.max_attempts < 1 ->
        invalid("max_attempts must be a positive integer", %{max_attempts: policy.max_attempts})

      not is_integer(policy.initial_delay) or policy.initial_delay < 0 ->
        invalid("initial_delay must be a non-negative integer", %{
          initial_delay: policy.initial_delay
        })

      not is_integer(policy.max_delay) or policy.max_delay < 0 ->
        invalid("max_delay must be a non-negative integer", %{max_delay: policy.max_delay})

      not is_number(policy.backoff) or policy.backoff < 0 ->
        invalid("backoff must be a non-negative number", %{backoff: policy.backoff})

      not valid_jitter?(policy.jitter) ->
        invalid("jitter must be false, true, or a non-negative integer", %{jitter: policy.jitter})

      not Policy.valid_timeout?(policy.timeout) ->
        invalid("timeout must be nil, :infinity, or a non-negative integer", %{
          timeout: policy.timeout
        })

      true ->
        {:ok, policy}
    end
  end

  @spec retry?(t(), Error.t() | term()) :: boolean()
  def retry?(%__MODULE__{retry_on: :all}, _error), do: true

  def retry?(%__MODULE__{retry_on: :transient}, error),
    do: BeamWeaver.RetryPredicates.transient?(error)

  def retry?(%__MODULE__{retry_on: :error}, %Error{}), do: true
  def retry?(%__MODULE__{retry_on: :error}, _error), do: false
  def retry?(%__MODULE__{retry_on: type}, %Error{type: type}) when is_atom(type), do: true
  def retry?(%__MODULE__{retry_on: type}, _error) when is_atom(type), do: false

  def retry?(%__MODULE__{retry_on: types}, %Error{type: type}) when is_list(types),
    do: type in types

  def retry?(%__MODULE__{retry_on: types}, _error) when is_list(types), do: false
  def retry?(%__MODULE__{retry_on: fun}, error) when is_function(fun, 1), do: fun.(error) == true

  def retry?(%__MODULE__{retry_on: {module, function, extra_args}}, error)
      when is_atom(module) and is_atom(function) and is_list(extra_args) do
    apply(module, function, [error | extra_args]) == true
  end

  def retry?(_policy, _error), do: false

  @spec delay(t(), pos_integer()) :: non_neg_integer()
  def delay(%__MODULE__{backoff: backoff} = policy, _attempt) when backoff == 0,
    do: policy.initial_delay |> min(policy.max_delay) |> add_jitter(policy.jitter) |> min(policy.max_delay)

  def delay(%__MODULE__{} = policy, attempt) when attempt >= 1 do
    policy.initial_delay
    |> multiply_delay(policy.backoff, attempt - 1)
    |> min(policy.max_delay)
    |> add_jitter(policy.jitter)
    |> min(policy.max_delay)
  end

  defp multiply_delay(delay, _backoff, 0), do: delay
  defp multiply_delay(delay, backoff, power), do: round(delay * :math.pow(backoff, power))

  defp add_jitter(delay, false), do: delay
  defp add_jitter(delay, true), do: delay + :rand.uniform(max(delay, 1)) - 1

  defp add_jitter(delay, jitter) when is_integer(jitter),
    do: delay + :rand.uniform(jitter + 1) - 1

  @doc """
  Returns the parent checkpoint namespace for a nested task namespace.

  LangGraph encodes nested task namespaces as pipe-separated `name:id` segments
  with optional numeric attempt markers. BeamWeaver keeps this as a pure helper so
  checkpoint/retry code can preserve the same parent-command routing behavior
  without exposing Python's private `_retry` module.
  """
  @spec checkpoint_parent_namespace(String.t() | nil) :: String.t()
  def checkpoint_parent_namespace(nil), do: ""
  def checkpoint_parent_namespace(""), do: ""

  def checkpoint_parent_namespace(namespace) when is_binary(namespace) do
    namespace
    |> String.split("|", trim: true)
    |> drop_trailing_attempt()
    |> drop_last_segment()
    |> drop_trailing_attempt()
    |> Enum.join("|")
  end

  defp valid_jitter?(value), do: value in [false, true] or (is_integer(value) and value >= 0)
  defp drop_last_segment([]), do: []
  defp drop_last_segment(segments), do: Enum.drop(segments, -1)

  defp drop_trailing_attempt([]), do: []

  defp drop_trailing_attempt(segments) do
    case List.last(segments) do
      segment when is_binary(segment) ->
        if Regex.match?(~r/^\d+$/, segment), do: Enum.drop(segments, -1), else: segments

      _segment ->
        segments
    end
  end

  defp normalize_value(key, value) when key in [:initial_delay, :max_delay],
    do: Policy.duration_to_ms(value)

  defp normalize_value(_key, value), do: value

  defp invalid(message, details), do: {:error, Error.new(:invalid_retry_policy, message, details)}
end
