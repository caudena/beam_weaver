defmodule BeamWeaver.Models.ParamPolicy do
  @moduledoc """
  Explicit model parameter validation policy.

  Known profiles default to strict validation. Unknown profiles remain
  permissive so new provider/model params can be passed while profile data
  catches up.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Models.Profile

  defstruct mode: :strict

  @type mode :: :strict | :warn | :permissive
  @type t :: %__MODULE__{mode: mode()}

  @standard_params MapSet.new([
                     :audio,
                     :background,
                     :betas,
                     :candidate_count,
                     :cache_control,
                     :conversation,
                     :context_management,
                     :container,
                     :dimensions,
                     :deferred,
                     :encoding_format,
                     :effort,
                     :frequency_penalty,
                     :cached_content,
                     :code_execution,
                     :diagnostics,
                     :function_call,
                     :functions,
                     :generation_config,
                     :image_config,
                     :include,
                     :include_thoughts,
                     :include_server_side_tool_invocations,
                     :instructions,
                     :inference_geo,
                     :labels,
                     :logit_bias,
                     :logprobs,
                     :max_completion_tokens,
                     :max_output_tokens,
                     :max_tokens,
                     :max_tool_calls,
                     :max_turns,
                     :metadata,
                     :media_resolution,
                     :modalities,
                     :mcp_servers,
                     :n,
                     :output_config,
                     :parallel_tool_calls,
                     :prediction,
                     :preview,
                     :presence_penalty,
                     :previous_response_id,
                     :prompt,
                     :prompt_cache_key,
                     :prompt_cache_retention,
                     :reasoning,
                     :reasoning_effort,
                     :response_format,
                     :response_format_config,
                     :response_json_schema,
                     :response_logprobs,
                     :response_mime_type,
                     :response_modalities,
                     :response_schema,
                     :retrieval_config,
                     :safety_identifier,
                     :safety_settings,
                     :seed,
                     :service_tier,
                     :speech_config,
                     :search_parameters,
                     :speed,
                     :stop,
                     :stop_sequences,
                     :store,
                     :tool_config,
                     :stream,
                     :stream_options,
                     :stream_usage,
                     :structured_output,
                     :temperature,
                     :text,
                     :thinking,
                     :thinking_budget,
                     :thinking_level,
                     :tool_choice,
                     :tools,
                     :top_logprobs,
                     :top_k,
                     :top_p,
                     :truncation,
                     :use_previous_response_id,
                     :user,
                     :user_profile_id,
                     :verbosity,
                     :web_search_options,
                     :x_grok_conv_id
                   ])

  @escape_hatches MapSet.new([:extra_body, :model_kwargs, :provider_opts])

  @aliases %{
    max_tokens: :max_output_tokens,
    max_completion_tokens: :max_output_tokens,
    structured_output: :response_format,
    stream: :streaming
  }

  @spec new(mode() | keyword() | map() | t() | nil) :: t()
  def new(nil), do: %__MODULE__{}
  def new(%__MODULE__{} = policy), do: policy
  def new(mode) when mode in [:strict, :warn, :permissive], do: %__MODULE__{mode: mode}
  def new(opts) when is_list(opts), do: opts |> Map.new() |> new()
  def new(%{mode: mode}) when mode in [:strict, :warn, :permissive], do: %__MODULE__{mode: mode}
  def new(%{"mode" => "strict"}), do: %__MODULE__{mode: :strict}
  def new(%{"mode" => "warn"}), do: %__MODULE__{mode: :warn}
  def new(%{"mode" => "permissive"}), do: %__MODULE__{mode: :permissive}

  def new(_other), do: %__MODULE__{}

  @spec default_for(Profile.t() | nil) :: t()
  def default_for(%Profile{extra: %{unknown: true}}), do: %__MODULE__{mode: :permissive}
  def default_for(%Profile{}), do: %__MODULE__{mode: :strict}
  def default_for(_profile), do: %__MODULE__{mode: :permissive}

  @doc """
  Validates user-supplied model params against a profile.

  Escape hatches are intentionally ignored here; they are provider-boundary maps.
  """
  @spec validate(Profile.t() | nil, keyword() | map(), t() | mode() | nil, keyword()) ::
          :ok | {:error, Error.t()}
  def validate(profile, params, policy, opts \\ []) do
    policy = policy || default_for(profile)
    policy = new(policy)
    api = Keyword.get(opts, :api)

    unsupported =
      params
      |> normalize_params()
      |> Enum.reject(fn {key, value} -> ignored_param?(key, value) end)
      |> Enum.filter(fn {key, _value} -> standard_param?(key) end)
      |> Enum.reject(fn {key, _value} -> supported?(profile, key, api) end)
      |> Enum.map(fn {key, _value} -> key end)
      |> Enum.uniq()

    case {policy.mode, unsupported} do
      {_mode, []} ->
        :ok

      {:permissive, _unsupported} ->
        :ok

      {:warn, unsupported} ->
        emit_warning(profile, unsupported, opts)
        :ok

      {:strict, unsupported} ->
        {:error,
         Error.new(:unsupported_model_param, "model parameter is not supported by profile", %{
           provider: profile_value(profile, :provider),
           model: profile_value(profile, :id),
           params: unsupported
         })}
    end
  end

  defp normalize_params(params) when is_list(params), do: params

  defp normalize_params(params) when is_map(params) do
    Enum.map(params, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_params(_params), do: []

  defp normalize_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp normalize_key(key), do: key

  defp ignored_param?(_key, nil), do: true
  defp ignored_param?(:stream, false), do: true

  defp ignored_param?(key, _value) when key in [:api, :model, :api_key, :endpoint, :transport],
    do: true

  defp ignored_param?(key, _value), do: MapSet.member?(@escape_hatches, key)

  defp standard_param?(key), do: MapSet.member?(@standard_params, key)

  defp supported?(profile, key, api)

  defp supported?(%Profile{} = profile, :stream, _api), do: profile.streaming == true

  defp supported?(%Profile{} = profile, key, nil),
    do: Profile.supports_param?(profile, aliased(key))

  defp supported?(%Profile{} = profile, key, api),
    do:
      Profile.supports_param?(profile, api, key) or
        Profile.supports_param?(profile, api, aliased(key))

  defp supported?(profile, key, _api), do: supported?(profile, key)

  defp supported?(_profile, _key), do: true

  defp aliased(key), do: Map.get(@aliases, key, key)

  defp emit_warning(profile, unsupported, opts) do
    :telemetry.execute(
      [:beam_weaver, :models, :param_warning],
      %{count: length(unsupported)},
      %{
        provider: profile_value(profile, :provider),
        model: profile_value(profile, :id),
        params: unsupported,
        metadata: Keyword.get(opts, :metadata, %{})
      }
    )
  end

  defp profile_value(%Profile{} = profile, key), do: Map.get(profile, key)
  defp profile_value(_profile, _key), do: nil
end
