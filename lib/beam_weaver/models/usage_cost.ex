defmodule BeamWeaver.Models.UsageCost do
  @moduledoc """
  Calculates token usage costs from model profile pricing metadata.

  Pricing is read from the profile's `extra` map using the canonical
  `input_price_per_mtok`, `cached_input_price_per_mtok`, and
  `output_price_per_mtok` keys. Explicit cache-hit and cache-miss token counts
  take precedence over deriving uncached input from the total. Profiles can
  also provide UTC `time_based_pricing`; when `:at` is supplied, its matching
  rate set overrides the canonical off-peak rates. `peak_iso_weekdays` limits
  the schedule to those weekdays when present. An optional `pricing_history`
  lists rate maps in chronological order, each with an ISO 8601 `effective_at`
  (or `nil` for the historical baseline). `:at` selects the applicable version;
  calls without a timestamp use the profile's current canonical rates.
  `long_context_pricing` overrides rates for the entire request when normalized
  total input, including cache reads and writes, exceeds its `threshold_tokens`.
  """

  alias BeamWeaver.Models.Profile

  @million 1_000_000
  @cache_write_dimensions [:cache_write_5m_tokens, :cache_write_1h_tokens, :cache_write_30m_tokens]
  @exact_dimension_keys Map.new(
                          [:input_tokens, :cached_input_tokens, :output_tokens | @cache_write_dimensions],
                          &{Atom.to_string(&1), &1}
                        )

  # Raw provider usage arrives as JSON; known keys are mapped to atoms once.
  @usage_keys ~w(input_tokens prompt_tokens output_tokens completion_tokens
                 prompt_cache_hit_tokens cache_hit_tokens cached_tokens
                 prompt_cache_miss_tokens cache_miss_tokens uncached_input_tokens
                 cache_write_tokens cache_creation_tokens cache_creation_input_tokens
                 cache_write_5m_tokens ephemeral_5m_input_tokens cache_write_1h_tokens
                 ephemeral_1h_input_tokens cache_write_30m_tokens input_token_details
                 prompt_tokens_details input_tokens_details cache_read cache_miss uncached
                 cache_write cache_creation cache_write_5m cache_write_1h cache_write_30m)a
  @usage_key_by_name Map.new(@usage_keys, &{Atom.to_string(&1), &1})

  @spec calculate(Profile.t() | map(), map(), keyword()) :: map() | nil
  def calculate(profile, usage, opts \\ [])

  def calculate(profile, usage, opts) when is_map(usage) and is_list(opts) do
    at = Keyword.get(opts, :at)
    usage = atomize_usage(usage)

    pricing =
      profile
      |> pricing()
      |> historical_pricing(at)
      |> scheduled_pricing(at)
      |> long_context_pricing(usage)

    input_price = number(pricing, :input_price_per_mtok)
    output_price = number(pricing, :output_price_per_mtok)

    if is_number(input_price) and is_number(output_price) do
      cached_price = number(pricing, :cached_input_price_per_mtok) || input_price
      input_tokens = input_tokens(usage)
      output_tokens = output_tokens(usage)
      cached_tokens = cached_tokens(usage)
      cache_writes = cache_write_tokens(usage, pricing)
      total_cache_write = Enum.sum(Map.values(cache_writes))
      uncached_tokens = uncached_tokens(usage, input_tokens, cached_tokens, total_cache_write)

      uncached_cost = mtok_cost(uncached_tokens, input_price)
      cached_cost = mtok_cost(cached_tokens, cached_price)
      cache_write_costs = cache_write_costs(cache_writes, pricing, input_price)
      cache_write_cost = Enum.sum(Map.values(cache_write_costs))
      output_cost = mtok_cost(output_tokens, output_price)
      input_cost = uncached_cost + cached_cost + cache_write_cost

      %{
        input_cost: input_cost,
        output_cost: output_cost,
        total_cost: input_cost + output_cost,
        input_cost_details:
          %{
            uncached: uncached_cost,
            cache_read: cached_cost
          }
          |> Map.merge(cache_write_costs),
        output_cost_details: %{
          text: output_cost
        }
      }
    end
  end

  def calculate(_profile, _usage, _opts), do: nil

  @doc """
  Calculates an integer USD-micro estimate from a closed, integer pricing map.

  Unlike `calculate/3`, this API never uses floating point rates. Each pricing
  dimension supplies a positive `unit_size` and non-negative
  `unit_price_usd_micros`; the sum is rounded half-up once at the end.
  """
  @spec calculate_usd_micros(map(), map()) :: {:ok, map()} | {:error, atom()}
  def calculate_usd_micros(
        %{schema_version: 1, currency: "USD", rounding: "half_up", dimensions: [_ | _]} = pricing,
        usage
      )
      when is_map(usage) do
    usage = atomize_usage(usage)

    with {:ok, counts} <- exact_usage(usage, pricing),
         {:ok, dimensions} <- exact_dimensions(pricing.dimensions, counts) do
      {numerator, denominator} =
        Enum.reduce(dimensions, {0, 1}, fn dimension, total ->
          add_fraction(total, {dimension.numerator, dimension.denominator})
        end)

      {:ok,
       %{
         cost_micros: round_half_up(numerator, denominator),
         currency: "USD",
         dimensions: dimensions,
         rounding: %{rule: "half_up", numerator: numerator, denominator: denominator}
       }}
    end
  end

  def calculate_usd_micros(_pricing, _usage), do: {:error, :invalid_pricing_profile}

  defp exact_usage(usage, pricing) do
    input = token_count(usage, [:input_tokens, :prompt_tokens])
    output = token_count(usage, [:output_tokens, :completion_tokens])
    cached = cached_tokens(usage)
    cache_writes = cache_write_tokens(usage, pricing)
    accounted_input = cached + Enum.sum(Map.values(cache_writes))

    if is_integer(input) and is_integer(output) and is_integer(cached) and
         Enum.all?(cache_writes, fn {_name, count} -> is_integer(count) end) and
         accounted_input <= input do
      {:ok, Map.merge(cache_writes, %{input_tokens: input, cached_input_tokens: cached, output_tokens: output})}
    else
      {:error, :invalid_usage}
    end
  end

  defp exact_dimensions(dimensions, counts) do
    priced = MapSet.new(dimensions, &dimension_field(&1, :name))

    dimensions
    |> Enum.reduce_while({MapSet.new(), []}, fn dimension, {names, result} ->
      name = dimension_field(dimension, :name)
      unit_size = dimension_field(dimension, :unit_size)
      unit_price = dimension_field(dimension, :unit_price_usd_micros)

      if Map.has_key?(@exact_dimension_keys, name) and not MapSet.member?(names, name) and
           is_integer(unit_size) and unit_size > 0 and is_integer(unit_price) and unit_price >= 0 do
        count = dimension_count(name, counts, priced)

        value = %{
          name: name,
          units: count,
          unit_size: unit_size,
          unit_price_usd_micros: unit_price,
          numerator: count * unit_price,
          denominator: unit_size
        }

        {:cont, {MapSet.put(names, name), [value | result]}}
      else
        {:halt, {:error, :invalid_pricing_dimension}}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      {_names, result} -> {:ok, Enum.reverse(result)}
    end
  end

  defp dimension_field(dimension, key) when is_map(dimension), do: Map.get(dimension, key)
  defp dimension_field(_dimension, _key), do: nil

  # Input that is priced through its own dimension is not billed again as input.
  defp dimension_count("input_tokens", counts, priced) do
    separated =
      @exact_dimension_keys
      |> Map.drop(["input_tokens", "output_tokens"])
      |> Enum.filter(fn {name, _key} -> MapSet.member?(priced, name) end)
      |> Enum.map(fn {_name, key} -> Map.fetch!(counts, key) end)
      |> Enum.sum()

    counts.input_tokens - separated
  end

  defp dimension_count(name, counts, _priced), do: Map.fetch!(counts, Map.fetch!(@exact_dimension_keys, name))

  defp add_fraction({left_numerator, left_denominator}, {right_numerator, right_denominator}) do
    numerator = left_numerator * right_denominator + right_numerator * left_denominator
    denominator = left_denominator * right_denominator
    divisor = Integer.gcd(numerator, denominator)
    {div(numerator, divisor), div(denominator, divisor)}
  end

  defp round_half_up(numerator, denominator), do: div(numerator * 2 + denominator, denominator * 2)

  defp pricing(%Profile{extra: extra}) when is_map(extra), do: extra

  defp pricing(profile) when is_map(profile) do
    case Map.get(profile, :extra) do
      extra when is_map(extra) -> extra
      _other -> profile
    end
  end

  defp pricing(_profile), do: %{}

  defp historical_pricing(pricing, %DateTime{} = at) do
    pricing
    |> Map.get(:pricing_history)
    |> List.wrap()
    |> Enum.reduce(pricing, fn entry, current ->
      case Map.get(entry, :effective_at) do
        nil ->
          merge_pricing_version(current, entry)

        value when is_binary(value) ->
          case DateTime.from_iso8601(value) do
            {:ok, effective_at, _offset} ->
              if DateTime.compare(effective_at, at) != :gt, do: merge_pricing_version(current, entry), else: current

            _ ->
              current
          end

        _ ->
          current
      end
    end)
  end

  defp historical_pricing(pricing, _at), do: pricing

  defp merge_pricing_version(pricing, version) do
    pricing = merge_rates(pricing, version)

    case Map.fetch(version, :time_based_pricing) do
      {:ok, schedule} -> Map.put(pricing, :time_based_pricing, schedule)
      :error -> pricing
    end
  end

  defp scheduled_pricing(pricing, %DateTime{} = at) do
    case Map.get(pricing, :time_based_pricing) do
      schedule when is_map(schedule) ->
        mode = if peak?(schedule, at), do: :peak, else: Map.get(schedule, :default_mode)

        case Map.get(schedule, mode) do
          rates when is_map(rates) -> merge_rates(pricing, rates)
          _other -> pricing
        end

      _other ->
        pricing
    end
  end

  defp scheduled_pricing(pricing, _at), do: pricing

  defp long_context_pricing(pricing, usage) do
    case Map.get(pricing, :long_context_pricing) do
      rates when is_map(rates) ->
        threshold = Map.get(rates, :threshold_tokens)

        if is_number(threshold) and input_tokens(usage) > threshold,
          do: merge_rates(pricing, rates),
          else: pricing

      _other ->
        pricing
    end
  end

  defp merge_rates(pricing, rates) do
    Enum.reduce(
      [
        :input_price_per_mtok,
        :cached_input_price_per_mtok,
        :output_price_per_mtok,
        :cache_write_5m_price_per_mtok,
        :cache_write_1h_price_per_mtok,
        :cache_write_30m_price_per_mtok
      ],
      pricing,
      fn key, merged ->
        case Map.fetch(rates, key) do
          {:ok, value} -> Map.put(merged, key, value)
          :error -> merged
        end
      end
    )
  end

  defp peak?(schedule, at) do
    utc = at |> DateTime.to_unix(:second) |> DateTime.from_unix!(:second)
    minute = utc.hour * 60 + utc.minute
    weekdays = Map.get(schedule, :peak_iso_weekdays)
    peak_day? = is_nil(weekdays) or Date.day_of_week(DateTime.to_date(utc)) in weekdays

    peak_day? and
      schedule
      |> Map.get(:peak_windows)
      |> List.wrap()
      |> Enum.any?(fn window ->
        start_minute = Map.get(window, :start_minute)
        end_minute = Map.get(window, :end_minute)

        is_integer(start_minute) and is_integer(end_minute) and
          minute >= start_minute and minute < end_minute
      end)
  end

  defp input_tokens(usage),
    do: token_count(usage, [:input_tokens, :prompt_tokens]) || 0

  defp output_tokens(usage),
    do: token_count(usage, [:output_tokens, :completion_tokens]) || 0

  defp cached_tokens(usage) do
    token_count(usage, [
      :prompt_cache_hit_tokens,
      :cache_hit_tokens,
      :cached_tokens
    ]) ||
      nested_token_count(usage, :input_token_details, [:cache_read, :cached_tokens]) ||
      nested_token_count(usage, :prompt_tokens_details, [:cached_tokens]) ||
      nested_token_count(usage, :input_tokens_details, [:cached_tokens]) ||
      0
  end

  defp uncached_tokens(usage, input_tokens, cached_tokens, cache_write_tokens) do
    token_count(usage, [
      :prompt_cache_miss_tokens,
      :cache_miss_tokens,
      :uncached_input_tokens
    ]) ||
      nested_token_count(usage, :input_token_details, [:cache_miss, :uncached]) ||
      max(input_tokens - cached_tokens - cache_write_tokens, 0)
  end

  defp cache_write_tokens(usage, pricing) do
    writes = %{
      cache_write_5m_tokens:
        token_count(usage, [:cache_write_5m_tokens, :ephemeral_5m_input_tokens]) ||
          nested_token_count(usage, :input_token_details, [
            :cache_write_5m,
            :cache_write_5m_tokens,
            :ephemeral_5m_input_tokens
          ]) || 0,
      cache_write_1h_tokens:
        token_count(usage, [:cache_write_1h_tokens, :ephemeral_1h_input_tokens]) ||
          nested_token_count(usage, :input_token_details, [
            :cache_write_1h,
            :cache_write_1h_tokens,
            :ephemeral_1h_input_tokens
          ]) || 0,
      cache_write_30m_tokens:
        token_count(usage, [:cache_write_30m_tokens]) ||
          nested_token_count(usage, :input_token_details, [
            :cache_write_30m,
            :cache_write_30m_tokens
          ]) || 0
    }

    generic =
      token_count(usage, [
        :cache_write_tokens,
        :cache_creation_tokens,
        :cache_creation_input_tokens
      ]) ||
        nested_token_count(usage, :input_token_details, [
          :cache_write,
          :cache_write_tokens,
          :cache_creation,
          :cache_creation_tokens,
          :cache_creation_input_tokens
        ]) || 0

    if generic > 0 and Enum.sum(Map.values(writes)) == 0 do
      case default_cache_write_dimension(pricing) do
        nil -> writes
        dimension -> Map.put(writes, dimension, generic)
      end
    else
      writes
    end
  end

  # The first priced TTL wins, in 5m, 1h, 30m order.
  defp default_cache_write_dimension(pricing),
    do: Enum.find(@cache_write_dimensions, &cache_write_priced?(pricing, &1))

  defp cache_write_priced?(%{dimensions: dimensions}, dimension) when is_list(dimensions),
    do: Enum.any?(dimensions, &(Map.get(&1, :name) == Atom.to_string(dimension)))

  defp cache_write_priced?(pricing, dimension), do: number(pricing, cache_write_price_key(dimension)) != nil

  defp cache_write_costs(cache_writes, pricing, input_price) do
    cache_writes
    |> Enum.filter(fn {_dimension, count} -> count > 0 end)
    |> Map.new(fn {dimension, count} ->
      {dimension, mtok_cost(count, number(pricing, cache_write_price_key(dimension)) || input_price)}
    end)
  end

  defp cache_write_price_key(:cache_write_5m_tokens), do: :cache_write_5m_price_per_mtok
  defp cache_write_price_key(:cache_write_1h_tokens), do: :cache_write_1h_price_per_mtok
  defp cache_write_price_key(:cache_write_30m_tokens), do: :cache_write_30m_price_per_mtok

  defp nested_token_count(usage, details_key, keys) do
    case Map.get(usage, details_key) do
      details when is_map(details) -> token_count(details, keys)
      _other -> nil
    end
  end

  defp token_count(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_number(value) -> max(value, 0)
        _other -> nil
      end
    end)
  end

  defp number(map, key) do
    case Map.get(map, key) do
      value when is_number(value) -> value
      _other -> nil
    end
  end

  defp mtok_cost(tokens, price_per_mtok), do: tokens * price_per_mtok / @million

  defp atomize_usage(usage) when is_map(usage),
    do: Map.new(usage, fn {key, value} -> {usage_key(key), atomize_usage(value)} end)

  defp atomize_usage(value), do: value

  defp usage_key(key) when is_binary(key), do: Map.get(@usage_key_by_name, key, key)
  defp usage_key(key), do: key
end
