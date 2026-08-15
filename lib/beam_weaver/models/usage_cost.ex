defmodule BeamWeaver.Models.UsageCost do
  @moduledoc """
  Calculates token usage costs from model profile pricing metadata.

  Pricing is read from the profile's `extra` map using the canonical
  `input_price_per_mtok`, `cached_input_price_per_mtok`, and
  `output_price_per_mtok` keys. Explicit cache-hit and cache-miss token counts
  take precedence over deriving uncached input from the total. Profiles can
  also provide UTC `time_based_pricing`; when `:at` is supplied, its matching
  rate set overrides the canonical off-peak rates.
  """

  alias BeamWeaver.MapAccess
  alias BeamWeaver.Models.Profile

  @million 1_000_000
  @exact_dimensions ~w(input_tokens cached_input_tokens output_tokens)

  @spec calculate(Profile.t() | map(), map(), keyword()) :: map() | nil
  def calculate(profile, usage, opts \\ [])

  def calculate(profile, usage, opts) when is_map(usage) and is_list(opts) do
    pricing = profile |> pricing() |> scheduled_pricing(Keyword.get(opts, :at))
    input_price = number(pricing, :input_price_per_mtok)
    output_price = number(pricing, :output_price_per_mtok)

    if is_number(input_price) and is_number(output_price) do
      cached_price = number(pricing, :cached_input_price_per_mtok) || input_price
      input_tokens = input_tokens(usage)
      output_tokens = output_tokens(usage)
      cached_tokens = cached_tokens(usage)
      uncached_tokens = uncached_tokens(usage, input_tokens, cached_tokens)

      uncached_cost = mtok_cost(uncached_tokens, input_price)
      cached_cost = mtok_cost(cached_tokens, cached_price)
      output_cost = mtok_cost(output_tokens, output_price)
      input_cost = uncached_cost + cached_cost

      %{
        input_cost: input_cost,
        output_cost: output_cost,
        total_cost: input_cost + output_cost,
        input_cost_details: %{
          uncached: uncached_cost,
          cache_read: cached_cost
        },
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
  def calculate_usd_micros(pricing, usage) when is_map(pricing) and is_map(usage) do
    with :ok <- exact_profile(pricing),
         {:ok, counts} <- exact_usage(usage),
         {:ok, dimensions} <- exact_dimensions(pricing, counts) do
      {numerator, denominator} =
        Enum.reduce(dimensions, {0, 1}, fn dimension, total ->
          add_fraction(total, {dimension.numerator, dimension.denominator})
        end)

      {:ok,
       %{
         cost_micros: round_half_up(numerator, denominator),
         currency: "USD",
         dimensions: dimensions,
         rounding: %{
           rule: "half_up",
           numerator: numerator,
           denominator: denominator
         }
       }}
    end
  end

  def calculate_usd_micros(_pricing, _usage), do: {:error, :invalid_pricing_profile}

  defp exact_profile(pricing) do
    if MapAccess.get(pricing, :schema_version) == 1 and
         MapAccess.get(pricing, :currency) == "USD" and
         MapAccess.get(pricing, :rounding) == "half_up" and
         is_list(MapAccess.get(pricing, :dimensions)) and
         MapAccess.get(pricing, :dimensions) != [] do
      :ok
    else
      {:error, :invalid_pricing_profile}
    end
  end

  defp exact_usage(usage) do
    input = token_count(usage, [:input_tokens, :prompt_tokens])
    output = token_count(usage, [:output_tokens, :completion_tokens])
    cached = cached_tokens(usage)

    if is_integer(input) and is_integer(output) and is_integer(cached) and cached <= input do
      {:ok, %{input_tokens: input, cached_input_tokens: cached, output_tokens: output}}
    else
      {:error, :invalid_usage}
    end
  end

  defp exact_dimensions(pricing, counts) do
    dimensions = MapAccess.get(pricing, :dimensions)
    cached_dimension? = Enum.any?(dimensions, &(MapAccess.get(&1, :name) == "cached_input_tokens"))

    dimensions
    |> Enum.reduce_while({MapSet.new(), []}, fn dimension, {names, result} ->
      name = MapAccess.get(dimension, :name)
      unit_size = MapAccess.get(dimension, :unit_size)
      unit_price = MapAccess.get(dimension, :unit_price_usd_micros)

      if name in @exact_dimensions and not MapSet.member?(names, name) and
           is_integer(unit_size) and unit_size > 0 and is_integer(unit_price) and unit_price >= 0 do
        count = dimension_count(name, counts, cached_dimension?)
        numerator = count * unit_price

        value = %{
          name: name,
          units: count,
          unit_size: unit_size,
          unit_price_usd_micros: unit_price,
          numerator: numerator,
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

  defp dimension_count("input_tokens", counts, true),
    do: counts.input_tokens - counts.cached_input_tokens

  defp dimension_count("input_tokens", counts, false), do: counts.input_tokens
  defp dimension_count("cached_input_tokens", counts, _cached?), do: counts.cached_input_tokens
  defp dimension_count("output_tokens", counts, _cached?), do: counts.output_tokens

  defp add_fraction({left_numerator, left_denominator}, {right_numerator, right_denominator}) do
    numerator = left_numerator * right_denominator + right_numerator * left_denominator
    denominator = left_denominator * right_denominator
    divisor = Integer.gcd(numerator, denominator)
    {div(numerator, divisor), div(denominator, divisor)}
  end

  defp round_half_up(numerator, denominator), do: div(numerator * 2 + denominator, denominator * 2)

  defp pricing(%Profile{extra: extra}) when is_map(extra), do: extra

  defp pricing(profile) when is_map(profile) do
    case MapAccess.get(profile, :extra) do
      extra when is_map(extra) -> extra
      _other -> profile
    end
  end

  defp pricing(_profile), do: %{}

  defp scheduled_pricing(pricing, %DateTime{} = at) do
    case MapAccess.get(pricing, :time_based_pricing) do
      schedule when is_map(schedule) ->
        mode = if peak?(schedule, at), do: :peak, else: MapAccess.get(schedule, :default_mode)

        case MapAccess.get(schedule, mode) do
          rates when is_map(rates) -> merge_rates(pricing, rates)
          _other -> pricing
        end

      _other ->
        pricing
    end
  end

  defp scheduled_pricing(pricing, _at), do: pricing

  defp merge_rates(pricing, rates) do
    Enum.reduce(
      [:input_price_per_mtok, :cached_input_price_per_mtok, :output_price_per_mtok],
      pricing,
      fn key, merged ->
        case MapAccess.fetch(rates, key) do
          {:ok, value} -> Map.put(merged, key, value)
          :error -> merged
        end
      end
    )
  end

  defp peak?(schedule, at) do
    utc = at |> DateTime.to_unix(:second) |> DateTime.from_unix!(:second)
    minute = utc.hour * 60 + utc.minute

    schedule
    |> MapAccess.get(:peak_windows)
    |> List.wrap()
    |> Enum.any?(fn window ->
      start_minute = MapAccess.get(window, :start_minute)
      end_minute = MapAccess.get(window, :end_minute)

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

  defp uncached_tokens(usage, input_tokens, cached_tokens) do
    token_count(usage, [
      :prompt_cache_miss_tokens,
      :cache_miss_tokens,
      :uncached_input_tokens
    ]) ||
      nested_token_count(usage, :input_token_details, [:cache_miss, :uncached]) ||
      max(input_tokens - cached_tokens, 0)
  end

  defp nested_token_count(usage, details_key, keys) do
    case MapAccess.get(usage, details_key) do
      details when is_map(details) -> token_count(details, keys)
      _other -> nil
    end
  end

  defp token_count(map, keys) do
    Enum.find_value(keys, fn key ->
      case MapAccess.get(map, key) do
        value when is_number(value) -> max(value, 0)
        _other -> nil
      end
    end)
  end

  defp number(map, key) do
    case MapAccess.get(map, key) do
      value when is_number(value) -> value
      _other -> nil
    end
  end

  defp mtok_cost(tokens, price_per_mtok), do: tokens * price_per_mtok / @million
end
