defmodule BeamWeaver.Models.UsageCost do
  @moduledoc """
  Calculates token usage costs from model profile pricing metadata.

  Pricing is read from the profile's `extra` map using the canonical
  `input_price_per_mtok`, `cached_input_price_per_mtok`, and
  `output_price_per_mtok` keys. Explicit cache-hit and cache-miss token counts
  take precedence over deriving uncached input from the total.
  """

  alias BeamWeaver.MapAccess
  alias BeamWeaver.Models.Profile

  @million 1_000_000

  @spec calculate(Profile.t() | map(), map()) :: map() | nil
  def calculate(profile, usage) when is_map(usage) do
    pricing = pricing(profile)
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

  def calculate(_profile, _usage), do: nil

  defp pricing(%Profile{extra: extra}) when is_map(extra), do: extra

  defp pricing(profile) when is_map(profile) do
    case MapAccess.get(profile, :extra) do
      extra when is_map(extra) -> extra
      _other -> profile
    end
  end

  defp pricing(_profile), do: %{}

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
