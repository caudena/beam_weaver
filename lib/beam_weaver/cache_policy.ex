defmodule BeamWeaver.CachePolicy do
  @moduledoc """
  Explicit cache policy used by graph nodes and model wrappers.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Policy

  defstruct namespace: :default,
            ttl: nil,
            metadata: %{},
            key: nil

  @fields [:namespace, :ttl, :metadata, :key]

  @type t :: %__MODULE__{
          namespace: term(),
          ttl: non_neg_integer() | nil,
          metadata: map(),
          key: nil | (term() -> term()) | {module(), atom(), list()}
        }

  def new(opts \\ [])
  def new(%__MODULE__{} = policy), do: validate(policy)
  def new(opts), do: Policy.build(__MODULE__, opts, @fields, &validate/1)

  def new!(opts \\ []), do: opts |> new() |> Policy.bang()

  def validate(%__MODULE__{} = policy) do
    cond do
      not (is_nil(policy.ttl) or (is_integer(policy.ttl) and policy.ttl >= 0)) ->
        {:error, Error.new(:invalid_cache_policy, "ttl must be nil or a non-negative integer")}

      not is_map(policy.metadata) ->
        {:error, Error.new(:invalid_cache_policy, "metadata must be a map")}

      not valid_key?(policy.key) ->
        {:error,
         Error.new(
           :invalid_cache_policy,
           "key must be nil, function/1, or {module, function, args}"
         )}

      true ->
        {:ok, policy}
    end
  end

  def key(%__MODULE__{key: nil}, payload), do: payload
  def key(%__MODULE__{key: fun}, payload) when is_function(fun, 1), do: fun.(payload)

  def key(%__MODULE__{key: {module, function, args}}, payload),
    do: apply(module, function, [payload | args])

  defp valid_key?(nil), do: true
  defp valid_key?(fun) when is_function(fun, 1), do: true

  defp valid_key?({module, function, args}),
    do: is_atom(module) and is_atom(function) and is_list(args)

  defp valid_key?(_other), do: false
end
