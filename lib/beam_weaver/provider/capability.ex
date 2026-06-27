defmodule BeamWeaver.Provider.Capability do
  @moduledoc """
  Provider and model capability helpers.

  Profiles remain the source of truth. This module gives the rest of
  BeamWeaver a feature-oriented vocabulary and a fail-fast validator for
  requested model behavior.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Models.Profile
  alias BeamWeaver.Options

  @feature_fields %{
    text_input: :text_inputs,
    image_input: :image_inputs,
    image_url_input: :image_url_inputs,
    pdf_input: :pdf_inputs,
    audio_input: :audio_inputs,
    video_input: :video_inputs,
    text_output: :text_outputs,
    image_output: :image_outputs,
    audio_output: :audio_outputs,
    video_output: :video_outputs,
    reasoning: :reasoning_output,
    thinking: :reasoning_output,
    tool_calling: :tool_calling,
    tool_call_streaming: :tool_call_streaming,
    tools: :tool_calling,
    tool_choice: :tool_choice,
    parallel_tool_calls: :parallel_tool_calls,
    structured_output: :structured_output,
    structured_output_with_tools: :structured_output_with_tools,
    streaming: :streaming,
    usage_metadata: :usage_metadata,
    responses_api: :responses_api,
    chat_completions_api: :chat_completions_api,
    image_tool_message: :image_tool_message,
    pdf_tool_message: :pdf_tool_message,
    attachment: :attachment
  }

  @doc """
  Returns whether a profile supports a feature.
  """
  @spec supports?(Profile.t() | nil, atom()) :: boolean()
  def supports?(%Profile{} = profile, feature) do
    case Map.fetch(@feature_fields, feature) do
      {:ok, field} -> Map.get(profile, field) == true
      :error -> Profile.supports?(profile, feature)
    end
  end

  def supports?(_profile, _feature), do: true

  @doc """
  Validates requested invocation features against a model profile.
  """
  @spec validate_invocation(term(), keyword()) :: :ok | {:error, Error.t()}
  def validate_invocation(model, opts) when is_list(opts) do
    profile = model_profile(model)
    provider = profile_value(profile, :provider) || provider_value(model)
    model_id = profile_value(profile, :id) || model_id(model)
    requested = requested_features(model, opts)

    unsupported =
      requested
      |> Enum.reject(&supports?(profile, &1))
      |> Enum.uniq()

    with {:ok, policy} <- unsupported_policy(opts) do
      case {policy, unsupported} do
        {_policy, []} ->
          :ok

        {:ignore, _features} ->
          :ok

        {:warn, features} ->
          emit_warning(provider, model_id, features, opts)
          :ok

        {_policy, [feature | _rest] = features} ->
          {:error,
           Error.new(:unsupported_feature, "requested model feature is not supported", %{
             provider: provider,
             model: model_id,
             feature: feature,
             features: features,
             supported: supported_features(profile)
           })}
      end
    end
  end

  @doc """
  Returns supported feature names for a profile.
  """
  @spec supported_features(Profile.t() | nil) :: [atom()]
  def supported_features(%Profile{} = profile) do
    @feature_fields
    |> Enum.flat_map(fn {feature, field} ->
      if Map.get(profile, field) == true, do: [feature], else: []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def supported_features(_profile), do: []

  defp requested_features(model, opts) do
    params = model_params(model) |> Keyword.merge(opts)

    []
    |> maybe_feature(:streaming, truthy?(params[:stream]) || truthy?(params[:streaming]))
    |> maybe_feature(:tools, non_empty?(params[:tools]))
    |> maybe_feature(:tool_choice, meaningful?(params[:tool_choice]))
    |> maybe_feature(:parallel_tool_calls, truthy?(params[:parallel_tool_calls]))
    |> maybe_feature(:structured_output, structured_output?(params))
    |> maybe_feature(:reasoning, reasoning_requested?(params))
    |> maybe_feature(:audio_output, audio_output_requested?(params))
    |> maybe_feature(:image_output, output_modality_requested?(params, "image"))
    |> maybe_feature(:video_output, output_modality_requested?(params, "video"))
  end

  defp model_params(%_module{} = model) do
    model
    |> Map.from_struct()
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == false or value == [] end)
  end

  defp model_params(_model), do: []

  defp maybe_feature(features, feature, true), do: [feature | features]
  defp maybe_feature(features, _feature, _false), do: features

  defp structured_output?(params) do
    meaningful?(params[:structured_output]) or meaningful?(params[:response_format]) or
      meaningful?(params[:output_config]) or meaningful?(params[:response_schema]) or
      meaningful?(params[:response_json_schema])
  end

  defp reasoning_requested?(params) do
    meaningful?(params[:reasoning]) or meaningful?(params[:reasoning_effort]) or
      meaningful?(params[:thinking]) or meaningful?(params[:thinking_level]) or
      meaningful?(params[:thinking_budget]) or meaningful?(params[:include_thoughts])
  end

  defp audio_output_requested?(params) do
    meaningful?(params[:audio]) or output_modality_requested?(params, "audio")
  end

  defp output_modality_requested?(params, modality) do
    params
    |> Keyword.get(:modalities, Keyword.get(params, :response_modalities, []))
    |> List.wrap()
    |> Enum.map(&(&1 |> to_string() |> String.downcase()))
    |> Enum.member?(modality)
  end

  defp truthy?(value), do: value == true
  defp non_empty?(value), do: value not in [nil, [], %{}]
  defp meaningful?(value), do: value not in [nil, false, [], %{}]

  defp unsupported_policy(opts) do
    value = Keyword.get(opts, :unsupported, :error)

    case Options.atom_enum_error("unsupported", value, [:ignore, :warn, :error]) do
      :ok ->
        {:ok, value}

      {:error, message} ->
        {:error,
         Error.new(:invalid_provider_option, message, %{
           option: :unsupported,
           value: inspect(value)
         })}
    end
  end

  defp emit_warning(provider, model, features, opts) do
    :telemetry.execute(
      [:beam_weaver, :provider, :unsupported_feature],
      %{count: length(features)},
      %{
        provider: provider,
        model: model,
        features: features,
        metadata: Keyword.get(opts, :metadata, %{})
      }
    )
  end

  defp model_profile(%{profile: %Profile{} = profile}), do: profile
  defp model_profile(_model), do: nil

  defp profile_value(%Profile{} = profile, key), do: Map.get(profile, key)
  defp profile_value(_profile, _key), do: nil

  defp model_id(%{model: model}) when is_binary(model), do: model
  defp model_id(%{id: id}) when is_binary(id), do: id
  defp model_id(_model), do: nil

  defp provider_value(%{provider: provider}), do: provider
  defp provider_value(_model), do: nil
end
