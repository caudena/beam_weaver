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
                     :prompt_cache_options,
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
                     :user_id,
                     :user_profile_id,
                     :verbosity,
                     :web_search_options,
                     :x_grok_conv_id
                   ])

  # The output cap has a different name on each API, and every model takes
  # all three, so a profile that lists one of them supports the others.
  @output_cap_params [:max_tokens, :max_completion_tokens, :max_output_tokens]

  @spec new(mode() | keyword() | map() | t() | nil) :: t()
  def new(nil), do: %__MODULE__{}
  def new(%__MODULE__{} = policy), do: policy
  def new(mode) when mode in [:strict, :warn, :permissive], do: %__MODULE__{mode: mode}
  def new(opts) when is_list(opts), do: opts |> Map.new() |> new()
  def new(%{mode: mode}) when mode in [:strict, :warn, :permissive], do: %__MODULE__{mode: mode}
  def new(%{"mode" => mode}) when mode in ["strict", "warn", "permissive"], do: new(String.to_existing_atom(mode))

  def new(_other), do: %__MODULE__{}

  @doc """
  Returns true for a standard model parameter: an option a chat or embedding
  call can carry, such as `:temperature`, `:tools` or `:stop`.
  """
  @spec standard_param?(term()) :: boolean()
  def standard_param?(key), do: MapSet.member?(@standard_params, key)

  @spec default_for(Profile.t() | nil) :: t()
  def default_for(%Profile{extra: %{unknown: true}}), do: %__MODULE__{mode: :permissive}
  def default_for(%Profile{}), do: %__MODULE__{mode: :strict}
  def default_for(_profile), do: %__MODULE__{mode: :permissive}

  @doc """
  Validates user-supplied model params against a profile.

  Escape hatches are intentionally ignored here; they are provider-boundary maps.
  In `:warn` mode, unsupported params emit a
  `[:beam_weaver, :models, :param_warning]` telemetry event that names the
  provider, the model and the params, never their values. `opts` takes
  `:api`, the API whose params the profile lists.
  """
  @spec validate(Profile.t() | nil, keyword() | map(), t() | mode() | nil, keyword()) ::
          :ok | {:error, Error.t()}
  def validate(profile, params, policy, opts \\ []) do
    policy = new(policy || default_for(profile))
    api = Keyword.get(opts, :api)

    unsupported =
      for {key, value} <- normalize_params(params),
          value != nil and {key, value} != {:stream, false},
          standard_param?(key),
          not supported?(profile, key, api),
          uniq: true,
          do: key

    case {policy.mode, unsupported} do
      {_mode, []} ->
        :ok

      {:permissive, _unsupported} ->
        :ok

      {:warn, unsupported} ->
        emit_warning(profile, unsupported)
        :ok

      {:strict, unsupported} ->
        {:error,
         Error.new(:unsupported_model_param, "model parameter is not supported by profile", %{
           provider: profile.provider,
           model: profile.id,
           params: unsupported
         })}
    end
  end

  defp normalize_params(params) when is_list(params), do: params

  defp normalize_params(params) when is_map(params) do
    Enum.map(params, fn {key, value} -> {BeamWeaver.MapAccess.existing_atom_key(key), value} end)
  end

  defp normalize_params(_params), do: []

  defp supported?(%Profile{} = profile, :stream, _api), do: profile.streaming == true

  defp supported?(%Profile{} = profile, key, api),
    do: Enum.any?(names(key), &Profile.supports_param?(profile, api, &1))

  defp supported?(_profile, _key, _api), do: true

  defp names(key) when key in @output_cap_params, do: @output_cap_params
  defp names(:structured_output), do: [:structured_output, :response_format]
  defp names(key), do: [key]

  defp emit_warning(profile, unsupported) do
    :telemetry.execute(
      [:beam_weaver, :models, :param_warning],
      %{count: length(unsupported)},
      %{provider: profile.provider, model: profile.id, params: unsupported}
    )
  end
end
