defmodule BeamWeaver.RetrievalPolicy do
  @moduledoc """
  Retrieval policy shared by retrievers, vectorstores, and file-search tools.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Policy

  defstruct k: 4,
            search_type: :similarity,
            filter: %{},
            score_threshold: nil,
            mmr_lambda: 0.5

  @fields [:k, :search_type, :filter, :score_threshold, :mmr_lambda]

  @type t :: %__MODULE__{
          k: pos_integer(),
          search_type: :similarity | :similarity_score | :mmr,
          filter: map(),
          score_threshold: number() | nil,
          mmr_lambda: number()
        }

  def new(opts \\ [])
  def new(%__MODULE__{} = policy), do: validate(policy)
  def new(opts), do: Policy.build(__MODULE__, opts, @fields, &validate/1)

  def new!(opts \\ []), do: opts |> new() |> Policy.bang()

  def validate(%__MODULE__{} = policy) do
    cond do
      not is_integer(policy.k) or policy.k < 1 ->
        {:error, Error.new(:invalid_retrieval_policy, "k must be a positive integer")}

      policy.search_type not in [:similarity, :similarity_score, :mmr] ->
        {:error, Error.new(:invalid_retrieval_policy, "unsupported search_type")}

      not is_map(policy.filter) ->
        {:error, Error.new(:invalid_retrieval_policy, "filter must be a map")}

      not (is_nil(policy.score_threshold) or is_number(policy.score_threshold)) ->
        {:error, Error.new(:invalid_retrieval_policy, "score_threshold must be nil or a number")}

      not is_number(policy.mmr_lambda) or policy.mmr_lambda < 0 or policy.mmr_lambda > 1 ->
        {:error, Error.new(:invalid_retrieval_policy, "mmr_lambda must be between 0 and 1")}

      true ->
        {:ok, policy}
    end
  end
end
