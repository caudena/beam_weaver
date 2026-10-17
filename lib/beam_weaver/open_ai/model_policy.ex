defmodule BeamWeaver.OpenAI.ModelPolicy do
  @moduledoc false

  @doc """
  Returns the constructor default temperature for a model when the caller did
  not set one explicitly.
  """
  @spec default_temperature(String.t() | nil, term()) :: term()
  def default_temperature(model, nil) do
    if o1_model?(model), do: 1, else: nil
  end

  def default_temperature(_model, temperature), do: temperature

  @doc """
  Returns the temperature that may be sent for a request.

  GPT-5 and GPT-6 family models reject temperature except when reasoning
  effort is explicitly `none`. GPT-6 Astra and GPT-6.1 Sol reject `none` reasoning.
  """
  @spec request_temperature(String.t() | nil, term(), map() | nil) :: term()
  def request_temperature(model, temperature, reasoning) do
    cond do
      is_nil(temperature) -> nil
      restricted_temperature_model?(model) and reasoning_effort(reasoning) != "none" -> nil
      true -> temperature
    end
  end

  @doc """
  Returns whether Chat Completions should send `max_tokens` as
  `max_completion_tokens` for this model family.
  """
  @spec completion_tokens_field_model?(String.t() | nil) :: boolean()
  def completion_tokens_field_model?(model) when is_binary(model) do
    normalized = String.downcase(model)

    String.starts_with?(normalized, "gpt-5") or gpt6?(normalized) or
      String.starts_with?(normalized, "o")
  end

  def completion_tokens_field_model?(_model), do: false

  @doc false
  def responses_tools_only?(model) when is_binary(model),
    do: String.downcase(model) in ["gpt-6-astra", "gpt-6.1-sol"]

  def responses_tools_only?(_model), do: false

  @doc false
  def gpt6?(model) when is_binary(model),
    do: String.downcase(model) in ["gpt-6-astra", "gpt-6.1-sol", "gpt-6-sol", "gpt-6-luna"]

  def gpt6?(_model), do: false

  @doc false
  def gpt6_sol_or_luna?(model) when is_binary(model),
    do: String.downcase(model) in ["gpt-6-sol", "gpt-6-luna"]

  def gpt6_sol_or_luna?(_model), do: false

  @doc false
  def none_reasoning?(reasoning), do: reasoning_effort(reasoning) == "none"

  @doc false
  def validate_gpt6_effort(model, reasoning, requested_effort) do
    supported =
      cond do
        responses_tools_only?(model) -> [:low, :medium, :high, :xhigh, :max]
        gpt6_sol_or_luna?(model) -> [:none, :low, :medium, :high, :xhigh, :max]
        true -> nil
      end

    if is_nil(supported) or reasoning_effort(reasoning) in [nil | Enum.map(supported, &Atom.to_string/1)] do
      :ok
    else
      {:error,
       BeamWeaver.Core.Error.new(:invalid_model_option, "GPT-6 reasoning effort is not supported by this model", %{
         model: model,
         reasoning_effort: requested_effort,
         supported: supported
       })}
    end
  end

  @doc false
  def validate_gpt6_sampling(model, reasoning, params) do
    if params != [] and gpt6_sol_or_luna?(model) and not none_reasoning?(reasoning) do
      {:error,
       BeamWeaver.Core.Error.new(:invalid_model_option, "GPT-6 sampling controls require reasoning effort none", %{
         model: model,
         params: params,
         expected_reasoning_effort: :none
       })}
    else
      :ok
    end
  end

  @doc false
  # Checks a reasoning effort against the model profile's list of efforts, on
  # OpenAI and xAI models whose profile has one.
  @spec validate_reasoning_effort(BeamWeaver.Models.Profile.t() | nil, term()) ::
          :ok | {:error, BeamWeaver.Core.Error.t()}
  def validate_reasoning_effort(
        %{provider: provider, reasoning_effort_levels: [_ | _] = efforts} = profile,
        reasoning
      )
      when provider in [:openai, :xai] do
    effort = reasoning_effort(reasoning)

    if is_nil(effort) or effort in Enum.map(efforts, &to_string/1) do
      :ok
    else
      {:error,
       BeamWeaver.Core.Error.new(:unsupported_model_param, "#{profile.id} does not take reasoning effort #{effort}", %{
         provider: provider,
         model: profile.id,
         params: [:reasoning_effort],
         value: effort,
         supported: efforts
       })}
    end
  end

  def validate_reasoning_effort(_profile, _reasoning), do: :ok

  defp o1_model?(model) when is_binary(model) do
    model
    |> String.downcase()
    |> String.starts_with?("o1")
  end

  defp o1_model?(_model), do: false

  defp restricted_temperature_model?(model) when is_binary(model) do
    normalized = String.downcase(model)

    String.starts_with?(normalized, "gpt-5") or gpt6?(normalized)
  end

  defp restricted_temperature_model?(_model), do: false

  defp reasoning_effort(%{"effort" => effort}) when is_atom(effort), do: Atom.to_string(effort)
  defp reasoning_effort(%{"effort" => effort}) when is_binary(effort), do: effort
  defp reasoning_effort(%{effort: effort}) when is_atom(effort), do: Atom.to_string(effort)
  defp reasoning_effort(%{effort: effort}) when is_binary(effort), do: effort
  defp reasoning_effort(nil), do: nil
  defp reasoning_effort(effort) when is_atom(effort), do: Atom.to_string(effort)
  defp reasoning_effort(effort) when is_binary(effort), do: effort
  defp reasoning_effort(_reasoning), do: nil
end
