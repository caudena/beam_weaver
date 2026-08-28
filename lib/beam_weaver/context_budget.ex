defmodule BeamWeaver.ContextBudget do
  @moduledoc """
  Conservative accounting for a final provider request.

  The model profile owns the input-limit semantics. Unknown limits fail closed;
  callers may not substitute an arbitrary context window.

  `estimated_tokens` is deliberately conservative unless the caller selects a
  conformance-approved local tokenizer. Provider-reported compatible usage is
  always a lower bound. Category input is expressed as exact encoded bytes and
  is allocated deterministically so the displayed categories sum to the final
  estimate.
  """

  alias BeamWeaver.Core.Error

  defstruct [
    :effective_input_limit,
    :estimated_tokens,
    :trigger_tokens,
    :free_tokens,
    :method,
    :version,
    :profile_hash,
    category_bytes: %{},
    categories: %{}
  ]

  @type t :: %__MODULE__{
          effective_input_limit: pos_integer(),
          estimated_tokens: non_neg_integer(),
          trigger_tokens: pos_integer(),
          free_tokens: non_neg_integer(),
          method: :conservative_utf8 | :local_tokenizer_v1,
          version: pos_integer(),
          profile_hash: String.t() | nil,
          category_bytes: %{optional(atom() | String.t()) => non_neg_integer()},
          categories: %{optional(atom() | String.t()) => non_neg_integer()}
        }

  @doc """
  Builds a conservative budget for rendered provider-request bytes.

  Options are `:trigger_ratio`, `:categories`, `:requested_max_output_tokens`,
  `:accounting_method`, `:reported_input_tokens`, and `:profile_hash`.
  """
  @spec new(map() | struct(), binary(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(profile, rendered_request, opts \\ [])

  def new(profile, rendered_request, opts) when is_binary(rendered_request) do
    trigger_ratio = Keyword.get(opts, :trigger_ratio, 0.85)
    categories = Keyword.get(opts, :categories, %{})

    with {:ok, limit} <- effective_input_limit(profile, opts),
         :ok <- validate_ratio(trigger_ratio),
         {:ok, categories} <- normalize_categories(categories),
         {:ok, reported} <- normalize_reported(Keyword.get(opts, :reported_input_tokens, 0)) do
      {method, local_estimate} = estimate(profile, rendered_request, categories, opts)
      estimated = max(local_estimate, reported)
      trigger = max(floor(limit * trigger_ratio), 1)
      category_tokens = allocate_categories(categories, estimated)

      {:ok,
       %__MODULE__{
         effective_input_limit: limit,
         estimated_tokens: estimated,
         trigger_tokens: trigger,
         free_tokens: max(limit - estimated, 0),
         method: method,
         version: 1,
         profile_hash: Keyword.get(opts, :profile_hash),
         category_bytes: categories,
         categories: category_tokens
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
        shared_input_limit(value(profile, :max_context_tokens, nil), reserved, requested_output)

      _unknown ->
        {:error, Error.new(:unknown_context_limit, "model context limit semantics are unknown")}
    end
  end

  defp positive_difference(limit, reserved)
       when is_integer(limit) and is_integer(reserved) and reserved >= 0 and limit > reserved,
       do: {:ok, limit - reserved}

  defp positive_difference(_limit, _reserved),
    do: {:error, Error.new(:unknown_context_limit, "model context limit is unavailable")}

  defp shared_input_limit(limit, reserved, requested_output)
       when is_integer(reserved) and reserved >= 0 and is_integer(requested_output) and
              requested_output >= 0,
       do: positive_difference(limit, reserved + requested_output)

  defp shared_input_limit(_limit, _reserved, _requested_output),
    do: {:error, Error.new(:unknown_context_limit, "model context limit is unavailable")}

  defp normalize_categories(categories) when is_map(categories) do
    if Enum.all?(categories, fn {_key, value} -> is_integer(value) and value >= 0 end),
      do: {:ok, categories},
      else: {:error, Error.new(:invalid_context_budget, "category costs must be non-negative integers")}
  end

  defp normalize_categories(_categories),
    do: {:error, Error.new(:invalid_context_budget, "categories must be a map")}

  defp estimate(profile, rendered_request, category_bytes, opts) do
    case Keyword.get(opts, :accounting_method, :conservative_utf8) do
      :local_tokenizer_v1 ->
        case BeamWeaver.Models.tokenizer_for(profile) do
          {:ok, tokenizer} ->
            case BeamWeaver.Core.LanguageModel.count_tokens({:tokenizer, tokenizer}, rendered_request) do
              {:ok, count} when is_integer(count) and count >= 0 ->
                {:local_tokenizer_v1, ceil(count * 1.10) + 256}

              _error ->
                conservative(rendered_request, category_bytes)
            end

          nil ->
            conservative(rendered_request, category_bytes)
        end

      _other ->
        conservative(rendered_request, category_bytes)
    end
  end

  defp conservative(rendered_request, category_bytes),
    do: {:conservative_utf8, max(byte_size(rendered_request), Enum.sum(Map.values(category_bytes)))}

  defp normalize_reported(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp normalize_reported(nil), do: {:ok, 0}

  defp normalize_reported(_value),
    do: {:error, Error.new(:invalid_context_budget, "reported usage must be a non-negative integer")}

  defp allocate_categories(category_bytes, estimated) do
    bytes = Enum.sum(Map.values(category_bytes))

    allocations =
      if bytes == 0 do
        %{}
      else
        category_bytes
        |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
        |> Enum.map_reduce(0, fn {key, value}, used ->
          allocated = div(estimated * value, bytes)
          {{key, allocated}, used + allocated}
        end)
        |> elem(0)
        |> Map.new()
      end

    residual = estimated - Enum.sum(Map.values(allocations))

    overhead_key =
      if Map.has_key?(allocations, "provider_overhead"),
        do: "provider_overhead",
        else: :provider_overhead

    Map.update(allocations, overhead_key, residual, &(&1 + residual))
  end

  defp validate_ratio(value) when is_float(value) and value > 0.0 and value < 1.0, do: :ok

  defp validate_ratio(_value),
    do: {:error, Error.new(:invalid_context_budget, "trigger ratio must be between zero and one")}

  defp value(%{} = map, key, default) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp value(_profile, _key, default), do: default
end
