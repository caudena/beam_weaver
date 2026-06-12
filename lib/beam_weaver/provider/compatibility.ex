defmodule BeamWeaver.Provider.Compatibility do
  @moduledoc """
  Programmatic compatibility matrix for registered providers and model profiles.
  """

  alias BeamWeaver.Models.Profile
  alias BeamWeaver.Provider.Capability
  alias BeamWeaver.Provider.Registry

  @features [
    :text_input,
    :image_input,
    :image_url_input,
    :pdf_input,
    :audio_input,
    :video_input,
    :text_output,
    :image_output,
    :audio_output,
    :video_output,
    :reasoning,
    :tool_calling,
    :tool_choice,
    :parallel_tool_calls,
    :structured_output,
    :structured_output_with_tools,
    :streaming,
    :usage_metadata,
    :responses_api,
    :chat_completions_api,
    :attachment
  ]

  @doc "Returns the standard feature columns in the compatibility matrix."
  def features, do: @features

  @doc "Returns one compatibility row per registered model profile."
  def matrix do
    Registry.profiles()
    |> Enum.map(&row/1)
    |> Enum.sort_by(&{to_string(&1.provider), &1.model})
  end

  @doc "Checks support for a feature on a profile, provider/model tuple, or model struct."
  def supports?(%Profile{} = profile, feature), do: Capability.supports?(profile, feature)

  def supports?({provider, model}, feature) do
    case Registry.profile(provider, model) do
      {:ok, profile} -> supports?(profile, feature)
      {:error, _error} -> false
    end
  end

  def supports?(%{profile: %Profile{} = profile}, feature), do: supports?(profile, feature)
  def supports?(_value, _feature), do: false

  defp row(%Profile{} = profile) do
    feature_map =
      @features
      |> Map.new(fn feature -> {feature, Capability.supports?(profile, feature)} end)

    %{
      provider: profile.provider,
      model: profile.id,
      name: profile.name,
      max_input_tokens: profile.max_input_tokens,
      max_output_tokens: profile.max_output_tokens,
      features: feature_map,
      supported_params: profile.supported_params,
      supported_params_by_api: profile.supported_params_by_api,
      extra: profile.extra
    }
  end
end
