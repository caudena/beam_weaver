defmodule BeamWeaver.Provider.ReasoningControl do
  @moduledoc """
  Pure resolution of provider reasoning controls from a frozen model profile.

  The returned controls are request inputs, not policy. Callers must freeze
  them with the rendered request so retry and recovery cannot reinterpret an
  effort value against newer registry metadata.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Models.Profile

  @effort_fractions %{
    "minimal" => {1, 20},
    "low" => {1, 10},
    "medium" => {1, 5},
    "high" => {7, 20},
    "xhigh" => {1, 2},
    "max" => {13, 20}
  }

  @spec resolve(Profile.t(), atom(), String.t() | atom() | nil, non_neg_integer()) ::
          {:ok, map()} | {:error, Error.t()}
  def resolve(%Profile{} = profile, provider, effort, output_reservation)
      when is_atom(provider) and is_integer(output_reservation) and output_reservation >= 0 do
    effort = normalize_effort(effort)
    extra = profile.extra || %{}
    thinking_mode = value(extra, :thinking_mode)

    case {provider, effort, profile.reasoning_output, extra, thinking_mode} do
      {_provider, effort, _reasoning, _extra, _mode} when effort in [nil, "none"] ->
        {:ok, %{}}

      {_provider, :invalid, _reasoning, _extra, _mode} ->
        incompatible_effort()

      {:anthropic, effort, true, extra, mode} when mode in [:adaptive_only, "adaptive_only"] ->
        if effort_supported?(extra, effort) do
          {:ok, %{thinking: %{type: "adaptive"}, effort: effort}}
        else
          incompatible_effort()
        end

      {:anthropic, effort, true, extra, _mode} ->
        if effort_supported?(extra, effort) do
          with {:ok, budget} <- budget(effort, output_reservation) do
            {:ok, %{thinking: %{type: "enabled", budget_tokens: budget}}}
          end
        else
          incompatible_effort()
        end

      {_provider, _effort, false, _extra, _mode} ->
        incompatible_effort()

      {_provider, _effort, _reasoning, _extra, _mode} ->
        {:ok, %{}}
    end
  end

  def resolve(%Profile{}, _provider, _effort, _output_reservation), do: incompatible_effort()

  defp budget(effort, output_reservation) do
    with {numerator, denominator} <- Map.get(@effort_fractions, effort),
         available when available >= 1_024 <- output_reservation - 1_024 do
      {:ok, min(max(div(output_reservation * numerator, denominator), 1_024), available)}
    else
      _other ->
        {:error,
         Error.new(
           :incompatible_reasoning_effort,
           "the requested output reservation cannot contain the selected thinking budget"
         )}
    end
  end

  defp effort_supported?(extra, effort) do
    levels = value(extra, :effort_levels, value(extra, :reasoning_efforts, []))

    Map.has_key?(@effort_fractions, effort) and
      (levels == [] or effort in Enum.map(levels, &to_string/1))
  end

  defp normalize_effort(nil), do: nil
  defp normalize_effort(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_effort(value) when is_binary(value), do: value
  defp normalize_effort(_value), do: :invalid

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp incompatible_effort do
    {:error,
     Error.new(
       :incompatible_reasoning_effort,
       "the selected model profile does not support the requested reasoning effort"
     )}
  end
end
