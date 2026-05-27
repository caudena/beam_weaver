defmodule BeamWeaver.OpenAI.ModelPolicy do
  @moduledoc """
  OpenAI model-family request policy.

  LangChain keeps several of these rules inside the ChatOpenAI constructor and
  payload builder. BeamWeaver keeps them as pure policy helpers so request
  builders, initializers, and tests can share the same behavior without
  exposing Python client internals.
  """

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

  GPT-5 family models reject temperature except when reasoning effort is
  explicitly `none`.
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
    String.starts_with?(normalized, "gpt-5") or String.starts_with?(normalized, "o")
  end

  def completion_tokens_field_model?(_model), do: false

  @doc """
  Returns whether a model should prefer the Responses API when callers have not
  explicitly selected an API.
  """
  @spec prefers_responses_api?(String.t() | nil) :: boolean()
  def prefers_responses_api?(model) when is_binary(model) do
    normalized = String.downcase(model)

    normalized in ["gpt-5.5-pro", "gpt-5.4-pro"]
  end

  def prefers_responses_api?(_model), do: false

  defp o1_model?(model) when is_binary(model) do
    model
    |> String.downcase()
    |> String.starts_with?("o1")
  end

  defp o1_model?(_model), do: false

  defp restricted_temperature_model?(model) when is_binary(model) do
    normalized = String.downcase(model)

    String.starts_with?(normalized, "gpt-5")
  end

  defp restricted_temperature_model?(_model), do: false

  defp reasoning_effort(%{"effort" => effort}) when is_atom(effort), do: Atom.to_string(effort)
  defp reasoning_effort(%{"effort" => effort}) when is_binary(effort), do: effort
  defp reasoning_effort(%{effort: effort}) when is_atom(effort), do: Atom.to_string(effort)
  defp reasoning_effort(%{effort: effort}) when is_binary(effort), do: effort
  defp reasoning_effort(_reasoning), do: nil
end
