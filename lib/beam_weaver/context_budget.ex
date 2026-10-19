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

  ## Accounting methods

  The budget's `method` names the method that produced `estimated_tokens`:

    * `:conservative_utf8`, the default, counts a token per encoded byte. It
      never under-counts, but for English text it is about four times the
      real count.
    * `:local_tokenizer_v1`, selected with
      `accounting_method: :local_tokenizer_v1`, counts with the profile's
      tokenizer and adds 10% plus 256 tokens.
    * `:reported_usage_delta_v2` starts from the input tokens the provider
      reported for an earlier request and adds the bytes of what changed
      since. It applies whenever `:reported_usage_baseline` and
      `:component_descriptors` describe the same components.

  A profile without a tokenizer, such as a Gemini profile, can't count
  locally. The budget then counts bytes and says why: `method` is
  `:conservative_utf8` and `fallback_reason` is `:no_tokenizer`, or
  `:tokenizer_failed` when the tokenizer can't count the request. Otherwise
  `fallback_reason` is `nil`.

      {:ok, profile} = BeamWeaver.Models.ProfileRegistry.fetch(:google, "gemini-3.5-flash")

      {:ok, budget} =
        BeamWeaver.ContextBudget.new(profile, "Check order A-1001.", accounting_method: :local_tokenizer_v1)

      budget.method
      #=> :conservative_utf8

      budget.fallback_reason
      #=> :no_tokenizer

  `BeamWeaver.Models.with_tokenizer/2` gives a profile a tokenizer: an
  OpenAI encoding such as `:o200k_base`, or an OpenAI model name. An OpenAI
  tokenizer can under-count another provider's tokens, so for other models
  prefer reported usage. `:reported_input_tokens`, the input tokens the
  provider reported last, is a lower bound for the byte and tokenizer counts.

  For `:reported_usage_delta_v2`, pass `:reported_usage_baseline`, which is
  `%{version: 2, input_tokens: tokens, components: descriptors}` for the
  request the provider reported on, and `:component_descriptors`, the same
  components described for the next request. A descriptor is
  `%{kind: :exact, bytes: bytes, hash: sha256_hex}` for a part such as the
  system prompt, or `%{kind: :append, items: [%{id: id, hash: hash, bytes: bytes}]}`
  for a part that grows, such as the message history.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.MapAccess

  defstruct [
    :effective_input_limit,
    :estimated_tokens,
    :trigger_tokens,
    :free_tokens,
    :method,
    :version,
    :profile_hash,
    :baseline_input_tokens,
    :delta_tokens,
    :fallback_reason,
    category_bytes: %{},
    categories: %{}
  ]

  @type t :: %__MODULE__{
          effective_input_limit: pos_integer(),
          estimated_tokens: non_neg_integer(),
          trigger_tokens: pos_integer(),
          free_tokens: non_neg_integer(),
          method: :conservative_utf8 | :local_tokenizer_v1 | :reported_usage_delta_v2,
          version: pos_integer(),
          profile_hash: String.t() | nil,
          baseline_input_tokens: non_neg_integer() | nil,
          delta_tokens: non_neg_integer() | nil,
          fallback_reason: :no_tokenizer | :tokenizer_failed | nil,
          category_bytes: %{optional(atom() | String.t()) => non_neg_integer()},
          categories: %{optional(atom() | String.t()) => non_neg_integer()}
        }

  @doc """
  Builds a conservative budget for rendered provider-request bytes.

  Options are `:trigger_ratio`, `:categories`, `:requested_max_output_tokens`,
  `:accounting_method`, `:reported_input_tokens`, `:reported_usage_baseline`,
  `:component_descriptors`, and `:profile_hash`. See
  [Accounting methods](#module-accounting-methods) for the accounting options
  and the budget's `fallback_reason`.
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
      {method, local_estimate, fallback_reason} = estimate(profile, rendered_request, categories, opts)

      {method, version, estimated, baseline, delta} =
        estimate_with_reported_delta(method, local_estimate, reported, opts)

      # Reported usage replaces the local estimate, so no fallback applies.
      fallback_reason = if method == :conservative_utf8, do: fallback_reason

      trigger = max(floor(limit * trigger_ratio), 1)
      category_tokens = allocate_categories(categories, estimated)

      {:ok,
       %__MODULE__{
         effective_input_limit: limit,
         estimated_tokens: estimated,
         trigger_tokens: trigger,
         free_tokens: max(limit - estimated, 0),
         method: method,
         version: version,
         profile_hash: Keyword.get(opts, :profile_hash),
         baseline_input_tokens: baseline,
         delta_tokens: delta,
         fallback_reason: fallback_reason,
         category_bytes: categories,
         categories: category_tokens
       }}
    end
  end

  def new(_profile, _rendered_request, _opts),
    do: {:error, Error.new(:invalid_rendered_request, "rendered request must be binary")}

  @doc """
  Resolves the usable input limit from the profile's `context_limit_kind`.

  `:separate_input` takes `max_input_tokens` less the provider-reserved
  tokens. `:shared_input_output`, a window the request and its output share,
  takes `max_context_tokens` less the reserved tokens and
  `:requested_max_output_tokens`. Any other kind fails with
  `:unknown_context_limit`.
  """
  @spec effective_input_limit(map() | struct(), keyword()) ::
          {:ok, pos_integer()} | {:error, Error.t()}
  def effective_input_limit(profile, opts \\ []) do
    kind = MapAccess.get(profile, :context_limit_kind, :unknown)
    reserved = MapAccess.get(profile, :provider_reserved_tokens, 0)
    requested_output = Keyword.get(opts, :requested_max_output_tokens, 0)

    case kind do
      kind when kind in [:separate_input, "separate_input"] ->
        positive_difference(MapAccess.get(profile, :max_input_tokens), reserved)

      kind when kind in [:shared_input_output, "shared_input_output"] ->
        shared_input_limit(MapAccess.get(profile, :max_context_tokens), reserved, requested_output)

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
        case tokenizer_count(profile, rendered_request) do
          {:ok, count} ->
            {:local_tokenizer_v1, ceil(count * 1.10) + 256, nil}

          {:error, reason} ->
            {:conservative_utf8, utf8_estimate(rendered_request, category_bytes), reason}
        end

      _conservative ->
        {:conservative_utf8, utf8_estimate(rendered_request, category_bytes), nil}
    end
  end

  defp tokenizer_count(profile, rendered_request) do
    case BeamWeaver.Models.tokenizer_for(profile) do
      {:ok, tokenizer} ->
        case BeamWeaver.Core.LanguageModel.count_tokens({:tokenizer, tokenizer}, rendered_request) do
          {:ok, count} when is_integer(count) and count >= 0 -> {:ok, count}
          _failed -> {:error, :tokenizer_failed}
        end

      nil ->
        {:error, :no_tokenizer}
    end
  end

  defp utf8_estimate(rendered_request, category_bytes),
    do: max(byte_size(rendered_request), Enum.sum(Map.values(category_bytes)))

  defp normalize_reported(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp normalize_reported(nil), do: {:ok, 0}

  defp normalize_reported(_value),
    do: {:error, Error.new(:invalid_context_budget, "reported usage must be a non-negative integer")}

  defp estimate_with_reported_delta(method, local_estimate, reported, opts) do
    baseline = Keyword.get(opts, :reported_usage_baseline)
    current = Keyword.get(opts, :component_descriptors)

    case reported_delta(baseline, current) do
      {:ok, baseline_tokens, delta} ->
        {:reported_usage_delta_v2, 2, baseline_tokens + delta, baseline_tokens, delta}

      :error ->
        {method, 1, max(local_estimate, reported), nil, nil}
    end
  end

  defp reported_delta(%{} = baseline, %{} = current) do
    with 2 <- MapAccess.get(baseline, :version),
         tokens when is_integer(tokens) and tokens >= 0 <- MapAccess.get(baseline, :input_tokens),
         %{} = previous <- MapAccess.get(baseline, :components),
         true <- map_size(previous) > 0 and map_size(current) > 0,
         {:ok, delta} <- component_delta(previous, current) do
      {:ok, tokens, delta}
    else
      _invalid -> :error
    end
  end

  defp reported_delta(_baseline, _current), do: :error

  defp component_delta(previous, current) do
    with {:ok, previous} <- normalize_component_map(previous),
         {:ok, current} <- normalize_component_map(current),
         true <- MapSet.new(Map.keys(previous)) == MapSet.new(Map.keys(current)) do
      Enum.reduce_while(current, {:ok, 0}, fn {key, descriptor}, {:ok, total} ->
        case descriptor_delta(Map.fetch!(previous, key), descriptor) do
          {:ok, delta} -> {:cont, {:ok, total + delta}}
          :error -> {:halt, :error}
        end
      end)
    else
      _invalid -> :error
    end
  end

  defp normalize_component_map(components) when is_map(components) do
    Enum.reduce_while(components, {:ok, %{}}, fn {key, descriptor}, {:ok, normalized} ->
      with {:ok, key} <- normalize_component_key(key),
           false <- Map.has_key?(normalized, key) do
        {:cont, {:ok, Map.put(normalized, key, descriptor)}}
      else
        _invalid -> {:halt, :error}
      end
    end)
  end

  defp normalize_component_key(key) when is_atom(key),
    do: normalize_component_key(Atom.to_string(key))

  defp normalize_component_key(key) when is_binary(key) and key != "", do: {:ok, key}
  defp normalize_component_key(_key), do: :error

  defp descriptor_delta(previous, current) do
    with {:ok, current} <- normalize_descriptor(current) do
      {:ok, unchanged_delta(normalize_descriptor(previous), current) || current.bytes}
    end
  end

  defp unchanged_delta({:ok, %{kind: :exact, bytes: bytes, hash: hash}}, %{kind: :exact, bytes: bytes, hash: hash}),
    do: 0

  defp unchanged_delta({:ok, %{kind: :append, items: previous}}, %{kind: :append, items: current}),
    do: appended_bytes(previous, current)

  defp unchanged_delta(_previous, _current), do: nil

  defp normalize_descriptor(descriptor) when is_map(descriptor) do
    case MapAccess.get(descriptor, :kind) do
      kind when kind in [:exact, "exact"] ->
        bytes = MapAccess.get(descriptor, :bytes)
        hash = MapAccess.get(descriptor, :hash)

        if is_integer(bytes) and bytes >= 0 and valid_hash?(hash),
          do: {:ok, %{kind: :exact, bytes: bytes, hash: hash}},
          else: :error

      kind when kind in [:append, "append"] ->
        with items when is_list(items) <- MapAccess.get(descriptor, :items),
             {:ok, items} <- normalize_items(items) do
          {:ok, %{kind: :append, items: items, bytes: Enum.sum_by(items, & &1.bytes)}}
        else
          _invalid -> :error
        end

      _other ->
        :error
    end
  end

  defp normalize_descriptor(_descriptor), do: :error

  defp normalize_items(items) do
    items =
      Enum.map(items, &%{id: MapAccess.get(&1, :id), hash: MapAccess.get(&1, :hash), bytes: MapAccess.get(&1, :bytes)})

    valid? =
      Enum.all?(items, fn item ->
        is_binary(item.id) and item.id != "" and valid_hash?(item.hash) and is_integer(item.bytes) and item.bytes >= 0
      end)

    if valid? and length(Enum.uniq_by(items, & &1.id)) == length(items), do: {:ok, items}, else: :error
  end

  defp appended_bytes([], current), do: Enum.sum_by(current, & &1.bytes)

  defp appended_bytes(
         [%{id: id, hash: hash, bytes: bytes} | previous],
         [%{id: id, hash: hash, bytes: bytes} | current]
       ),
       do: appended_bytes(previous, current)

  defp appended_bytes(_previous, _current), do: nil

  defp valid_hash?(hash), do: is_binary(hash) and hash =~ ~r/\A[0-9a-f]{64}\z/

  defp allocate_categories(category_bytes, estimated) do
    bytes = Enum.sum(Map.values(category_bytes))

    allocations =
      if bytes == 0,
        do: %{},
        else: Map.new(category_bytes, fn {key, value} -> {key, div(estimated * value, bytes)} end)

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
end
