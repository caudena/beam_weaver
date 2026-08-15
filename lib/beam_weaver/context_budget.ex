defmodule BeamWeaver.ContextBudget do
  @moduledoc """
  Conservative accounting for a final provider request.

  The model profile owns the input-limit semantics. Unknown limits fail closed;
  callers may not substitute an arbitrary context window.

  `estimated_tokens` is deliberately conservative UTF-8 byte accounting, not a
  claim of tokenizer-exact usage. When categories are supplied, the estimate is
  the greater of the rendered-request byte size and the category total.
  """

  alias BeamWeaver.Core.Error

  defstruct [
    :effective_input_limit,
    :estimated_tokens,
    :trigger_tokens,
    :free_tokens,
    :method,
    categories: %{}
  ]

  @type t :: %__MODULE__{
          effective_input_limit: pos_integer(),
          estimated_tokens: non_neg_integer(),
          trigger_tokens: pos_integer(),
          free_tokens: non_neg_integer(),
          method: :conservative_utf8,
          categories: %{optional(atom() | String.t()) => non_neg_integer()}
        }

  @doc """
  Builds a conservative budget for rendered provider-request bytes.

  Options are `:trigger_ratio`, `:categories`, and
  `:requested_max_output_tokens`.
  """
  @spec new(map() | struct(), binary(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(profile, rendered_request, opts \\ [])

  def new(profile, rendered_request, opts) when is_binary(rendered_request) do
    trigger_ratio = Keyword.get(opts, :trigger_ratio, 0.85)
    categories = Keyword.get(opts, :categories, %{})

    with {:ok, limit} <- effective_input_limit(profile, opts),
         :ok <- validate_ratio(trigger_ratio),
         {:ok, categories} <- normalize_categories(categories) do
      estimated = max(byte_size(rendered_request), Enum.sum(Map.values(categories)))
      trigger = max(floor(limit * trigger_ratio), 1)

      {:ok,
       %__MODULE__{
         effective_input_limit: limit,
         estimated_tokens: estimated,
         trigger_tokens: trigger,
         free_tokens: max(limit - estimated, 0),
         method: :conservative_utf8,
         categories: categories
       }}
    end
  end

  def new(_profile, _rendered_request, _opts),
    do: {:error, Error.new(:invalid_rendered_request, "rendered request must be binary")}

  @doc """
  Resolves the usable input limit from the profile's declared limit semantics.

  Separate input limits subtract provider-reserved tokens. Shared
  input/output limits also subtract `:requested_max_output_tokens`.
  """
  @spec effective_input_limit(map() | struct(), keyword()) ::
          {:ok, pos_integer()} | {:error, Error.t()}
  def effective_input_limit(profile, opts \\ []) do
    kind = value(profile, :context_limit_kind, :unknown)
    reserved = value(profile, :provider_reserved_tokens, 0)
    requested_output = Keyword.get(opts, :requested_max_output_tokens, 0)

    case kind do
      kind when kind in [:separate_input, "separate_input"] ->
        positive_difference(value(profile, :max_input_tokens, nil), reserved)

      kind when kind in [:shared_input_output, "shared_input_output"] ->
        positive_difference(
          value(profile, :max_context_tokens, nil),
          reserved + requested_output
        )

      _unknown ->
        {:error, Error.new(:unknown_context_limit, "model context limit semantics are unknown")}
    end
  end

  defp positive_difference(limit, reserved)
       when is_integer(limit) and is_integer(reserved) and reserved >= 0 and limit > reserved,
       do: {:ok, limit - reserved}

  defp positive_difference(_limit, _reserved),
    do: {:error, Error.new(:unknown_context_limit, "model context limit is unavailable")}

  defp normalize_categories(categories) when is_map(categories) do
    if Enum.all?(categories, fn {_key, value} -> is_integer(value) and value >= 0 end),
      do: {:ok, categories},
      else: {:error, Error.new(:invalid_context_budget, "category costs must be non-negative integers")}
  end

  defp normalize_categories(_categories),
    do: {:error, Error.new(:invalid_context_budget, "categories must be a map")}

  defp validate_ratio(value) when is_float(value) and value > 0.0 and value < 1.0, do: :ok

  defp validate_ratio(_value),
    do: {:error, Error.new(:invalid_context_budget, "trigger ratio must be between zero and one")}

  defp value(%{} = map, key, default) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp value(_profile, _key, default), do: default
end
