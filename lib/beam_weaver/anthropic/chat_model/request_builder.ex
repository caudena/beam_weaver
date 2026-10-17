defmodule BeamWeaver.Anthropic.ChatModel.RequestBuilder do
  @moduledoc false

  import BeamWeaver.Provider.Options, only: [option: 3]

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Anthropic.ChatModel.ModelResolution
  alias BeamWeaver.Anthropic.Messages
  alias BeamWeaver.Anthropic.Tools
  alias BeamWeaver.MapAccess
  alias BeamWeaver.Models.ParamPolicy
  alias BeamWeaver.Provider.Options

  @supported_model_params [
    :betas,
    :cache_control,
    :compaction,
    :container,
    :context_management,
    :diagnostics,
    :effort,
    :extra_body,
    :fallback_credit_token,
    :fallbacks,
    :inference_geo,
    :max_tokens,
    :metadata,
    :mcp_servers,
    :output_config,
    :parallel_tool_calls,
    :reasoning_effort,
    :response_format,
    :service_tier,
    :speed,
    :stop_sequences,
    :stream,
    :stream_usage,
    :structured_output,
    :temperature,
    :thinking,
    :tool_choice,
    :tools,
    :top_k,
    :top_p,
    :user_profile_id,
    :workspace_id
  ]

  @reserved_body_fields [
    :betas,
    :cache_control,
    :compaction,
    :container,
    :context_management,
    :diagnostics,
    :fallback_credit_token,
    :fallbacks,
    :inference_geo,
    :max_tokens,
    :messages,
    :mcp_servers,
    :metadata,
    :model,
    :output_config,
    :service_tier,
    :speed,
    :stop_sequences,
    :stream,
    :system,
    :temperature,
    :thinking,
    :tool_choice,
    :tools,
    :top_k,
    :top_p,
    :user_profile_id,
    :workspace_id
  ]

  @unsupported "model parameter is not supported by profile"

  @spec request_body(term(), [BeamWeaver.Core.Message.t()], keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def request_body(model, messages, opts) do
    with {:ok, model} <- ModelResolution.resolve(model, opts),
         :ok <- validate_request_params(model, opts),
         :ok <- validate_metadata(option(model, opts, :metadata), model.model),
         :ok <- validate_sampling_params(model, opts),
         :ok <- validate_effort(model, opts),
         :ok <- validate_thinking_params(model, opts),
         :ok <- validate_tool_compatibility(model, opts),
         :ok <- validate_model_features(model, opts),
         :ok <- validate_fallback_credit_params(model, opts),
         fallbacks = option(model, opts, :fallbacks),
         {:ok, body} <- shared_body(model, messages, opts, fallbacks, option(model, opts, :fallback_credit_token)) do
      {:ok,
       body
       |> Map.put("max_tokens", max_tokens(model, opts))
       |> put_options(model, opts, [:metadata, :diagnostics, :fallback_credit_token], &Options.normalize_option_map/1)
       |> put_options(model, opts, [:container, :temperature, :top_k, :top_p])
       |> put_options(model, opts, [:service_tier, :inference_geo, :fallbacks], &Options.normalize_value/1)
       |> Options.put_optional("stream", Keyword.get(opts, :stream))
       |> Options.put_optional("stop_sequences", option(model, opts, :stop_sequences) || Keyword.get(opts, :stop))
       |> maybe_put_container(model, messages, opts)
       |> Options.merge_extra_body(Options.extra_body(model, opts), reserved: @reserved_body_fields)}
    end
  end

  @spec count_tokens_body(term(), [BeamWeaver.Core.Message.t()], keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def count_tokens_body(model, messages, opts) do
    with {:ok, model} <- ModelResolution.resolve(model, opts),
         :ok <- validate_effort(model, opts),
         :ok <- validate_thinking_params(model, opts),
         :ok <- validate_tool_compatibility(model, opts),
         do: shared_body(model, messages, opts, nil, nil)
  end

  defp shared_body(model, messages, opts, fallbacks, fallback_credit_token) do
    message_opts = [mid_conversation_system_messages: profile_extra(model, :mid_conversation_system_messages) == true]

    with {:ok, {system, formatted_messages}} <- Messages.format_messages(messages, message_opts),
         :ok <- validate_final_turn(model, formatted_messages, opts),
         :ok <- validate_per_turn_effort(model, formatted_messages, opts),
         {:ok, output_config} <- output_config(model, opts),
         :ok <- validate_compaction_params(model, opts, output_config) do
      tools = tools(opts)
      betas = betas(model, opts, tools, output_config, formatted_messages, fallbacks, fallback_credit_token)

      {:ok,
       %{"model" => model.model, "messages" => formatted_messages}
       |> put_options(model, opts, [:cache_control, :compaction, :context_management], &Options.normalize_option_map/1)
       |> put_options(model, opts, [:speed], &Options.normalize_value/1)
       |> Options.put_optional("system", system)
       |> Options.put_optional("tools", tools)
       |> Options.put_optional("tool_choice", tool_choice(model, opts))
       |> Options.put_optional("thinking", Options.normalize_option_map(thinking(model, opts)))
       |> Options.put_optional("output_config", output_config)
       |> Options.put_optional("mcp_servers", Options.normalize_option_list(option(model, opts, :mcp_servers)))
       |> Options.put_optional("betas", betas)}
    end
  end

  defp put_options(body, model, opts, keys, normalize \\ & &1),
    do: Enum.reduce(keys, body, &Options.put_optional(&2, Atom.to_string(&1), normalize.(option(model, opts, &1))))

  defp validate_request_params(model, opts) do
    model_params =
      model
      |> Map.from_struct()
      |> Map.take(@supported_model_params)

    # Every model parameter of the call is checked, so a foreign option such
    # as `frequency_penalty` is an error rather than dropped.
    params = Map.merge(model_params, Map.new(opts))

    ParamPolicy.validate(model.profile, params, option(model, opts, :param_policy))
  end

  @max_user_id_length 512

  @doc false
  # Anthropic's API reference gives the request `metadata` one field,
  # `user_id`, a string of at most 512 characters (or null). A model's
  # metadata is checked when the model is created (see
  # `BeamWeaver.Anthropic.Provider`) and with each call's.
  @spec validate_metadata(term(), String.t() | nil) :: :ok | {:error, Error.t()}
  def validate_metadata(nil, _model), do: :ok

  def validate_metadata(metadata, model) when is_map(metadata) do
    {user_ids, others} = Map.split(metadata, [:user_id, "user_id"])
    user_ids = user_ids |> Map.values() |> Enum.reject(&is_nil/1)

    cond do
      others != %{} ->
        keys = Map.keys(others)

        request_error(
          model,
          [params: [:metadata], keys: keys],
          "Anthropic metadata takes only :user_id, not #{Enum.map_join(keys, ", ", &inspect/1)}"
        )

      not Enum.all?(user_ids, &is_binary/1) ->
        request_error(
          model,
          [params: [:metadata], field: "metadata.user_id", expected: :string],
          "Anthropic metadata :user_id must be a string"
        )

      Enum.any?(user_ids, &Options.longer_than?(&1, @max_user_id_length)) ->
        request_error(
          model,
          [params: [:metadata], field: "metadata.user_id", max_length: @max_user_id_length],
          "Anthropic metadata :user_id takes at most #{@max_user_id_length} characters"
        )

      true ->
        :ok
    end
  end

  def validate_metadata(_metadata, model),
    do:
      request_error(model, [params: [:metadata], expected: :map], "Anthropic metadata must be a map with only :user_id")

  defp request_error(model_name, details, message \\ @unsupported, type \\ :unsupported_model_param),
    do: {:error, Error.new(type, message, Enum.into(details, %{provider: :anthropic, model: model_name}))}

  defp validate_sampling_params(model, opts) do
    controls = profile_extra(model, :sampling_controls)
    default_only? = controls in [:default_only, "default_only"]
    temperature = option(model, opts, :temperature)
    top_p = option(model, opts, :top_p)

    params =
      for {param, true} <- [
            temperature: temperature not in [nil, 1, 1.0],
            top_k: not is_nil(option(model, opts, :top_k)),
            top_p: not is_nil(top_p) and top_p !== 0.99 and (default_only? or not (is_number(top_p) and top_p > 0.99))
          ],
          do: param

    params =
      if default_only? and not is_nil(temperature) and not is_nil(top_p),
        do: Enum.uniq(params ++ [:temperature, :top_p]),
        else: params

    if controls in [:restricted, "restricted", :default_only, "default_only"] and params != [] do
      request_error(model.model,
        params: params,
        reason: "Anthropic restricts temperature, top_k, and top_p for this Claude model"
      )
    else
      :ok
    end
  end

  defp validate_thinking_params(model, opts) do
    thinking = thinking(model, opts)

    with :ok <- validate_thinking_shape(model, thinking),
         :ok <- validate_thinking_mode(model, thinking_type(thinking)),
         :ok <- validate_reduced_thinking_effort(model, opts, thinking_type(thinking)) do
      validate_thinking_block_binding(model, thinking)
    end
  end

  defp validate_thinking_shape(_model, thinking) when is_nil(thinking) or is_map(thinking), do: :ok

  defp validate_thinking_shape(model, thinking) do
    request_error(
      model.model,
      [params: [:thinking], expected: :map, value: inspect(thinking)],
      "model parameter has an invalid shape"
    )
  end

  defp validate_thinking_mode(model, type) do
    supported = profile_extra(model, :thinking_types)

    cond do
      is_list(supported) and not is_nil(type) ->
        if Enum.any?(supported, &(type == &1 or type == to_string(&1))) do
          :ok
        else
          request_error(model.model,
            params: [:thinking],
            reason: "This Claude model supports thinking types: #{Enum.join(supported, ", ")}",
            supported: supported
          )
        end

      always_on_thinking_model?(model) and type in [:disabled, "disabled"] ->
        request_error(model.model, params: [:thinking], reason: "Thinking is always on for this Claude model")

      adaptive_only_thinking_model?(model) and type not in [nil, :adaptive, "adaptive", :disabled, "disabled"] ->
        request_error(model.model,
          params: [:thinking],
          reason: "This Claude model only supports adaptive thinking or disabled thinking"
        )

      true ->
        :ok
    end
  end

  defp validate_reduced_thinking_effort(model, opts, type) do
    max_effort =
      cond do
        type in [:disabled, "disabled"] -> profile_extra(model, :thinking_disabled_max_effort)
        type in [:between_tools, "between_tools"] -> profile_extra(model, :thinking_between_tools_max_effort)
        true -> nil
      end

    if not is_nil(max_effort) and effort_rank(request_effort(model, opts)) > effort_rank(max_effort) do
      request_error(model.model,
        params: [:thinking, :effort],
        reason: "Thinking type #{type} is only supported at #{max_effort} effort or below"
      )
    else
      :ok
    end
  end

  defp validate_thinking_block_binding(model, thinking) do
    case MapAccess.get(thinking, :block_binding) do
      nil ->
        :ok

      binding ->
        if thinking_type(thinking) in [:adaptive, "adaptive"] and
             MapAccess.get(binding, :prefix_mismatch_behavior) in [:error, "error", :drop_block, "drop_block"] do
          :ok
        else
          request_error(model.model,
            params: [:thinking],
            field: "thinking.block_binding.prefix_mismatch_behavior",
            supported: [:error, :drop_block]
          )
        end
    end
  end

  defp validate_per_turn_effort(model, messages, opts) do
    reduced? = thinking_type(thinking(model, opts)) in [:disabled, "disabled", :between_tools, "between_tools"]
    effort = request_effort(model, opts)

    changed? =
      Enum.any?(messages, fn message ->
        per_turn = output_config_effort(message["output_config"])
        not is_nil(per_turn) and to_string(per_turn) != to_string(effort)
      end)

    if reduced? and is_list(profile_extra(model, :thinking_types)) and changed? do
      request_error(model.model, [params: [:thinking, :effort]], "Effort cannot change per turn with reduced thinking")
    else
      :ok
    end
  end

  defp validate_tool_compatibility(model, opts) do
    modes = profile_extra(model, :tool_choice_modes)

    if is_list(modes) and :any not in modes and forced_tool_choice?(Keyword.get(opts, :tool_choice)) do
      request_error(model.model,
        params: [:tool_choice],
        reason: "This Claude model supports only auto or none tool choice",
        supported: modes
      )
    else
      tools = List.wrap(tools(opts))
      unsupported_advisors = profile_extra(model, :unsupported_advisor_models) || []
      unsupported_server_tools = profile_extra(model, :unsupported_server_tools) || []

      advisors =
        for %{"type" => "advisor_" <> _version} = tool <- tools,
            tool["model"] in unsupported_advisors,
            uniq: true,
            do: tool["model"]

      server_tools = tools |> Enum.map(&server_tool_family/1) |> Enum.filter(&(&1 in unsupported_server_tools))

      cond do
        advisors != [] ->
          request_error(
            model.model,
            [params: [:tools], unsupported_advisor_models: advisors],
            "advisor model is not supported by the executor",
            :unsupported_feature
          )

        server_tools != [] ->
          request_error(
            model.model,
            [params: [:tools], unsupported_server_tools: Enum.uniq(server_tools)],
            "server tool is not supported by model",
            :unsupported_feature
          )

        true ->
          :ok
      end
    end
  end

  defp validate_final_turn(model, messages, opts) do
    compaction? = not is_nil(option(model, opts, :compaction))
    last = List.last(messages)
    final_assistant? = match?(%{"role" => "assistant"}, last)

    cond do
      compaction? and final_assistant? and is_list(last["content"]) and
          Enum.any?(last["content"], &match?(%{"type" => "tool_use"}, &1)) ->
        request_error(
          model.model,
          [role: :assistant, requirement: :completed_tool_results],
          "Anthropic compaction requires completed tool results",
          :invalid_message
        )

      not compaction? and final_assistant? and profile_extra(model, :prefilled_model_turns) == false and
          not fallback_credit_prefill?(model, opts) ->
        request_error(
          model.model,
          [role: :assistant, requirement: :final_user_tool_or_system_turn],
          "Anthropic model requests cannot end with an assistant turn",
          :invalid_message
        )

      true ->
        :ok
    end
  end

  defp fallback_credit_prefill?(model, opts) do
    not is_nil(option(model, opts, :fallback_credit_token)) and
      not forced_tool_choice?(Keyword.get(opts, :tool_choice)) and
      is_nil(Keyword.get(opts, :response_format)) and
      is_nil(Keyword.get(opts, :structured_output)) and
      is_nil(MapAccess.get(option(model, opts, :output_config), :format))
  end

  defp validate_fallback_credit_params(model, opts) do
    token = option(model, opts, :fallback_credit_token)

    cond do
      not is_nil(token) and option(model, opts, :fallbacks) not in [nil, []] ->
        request_error(
          model.model,
          [params: [:fallback_credit_token, :fallbacks]],
          "Anthropic fallback credit cannot be combined with fallbacks"
        )

      valid_fallback_credit_token?(token) ->
        :ok

      true ->
        request_error(
          model.model,
          [params: [:fallback_credit_token], expected: :non_empty_string_or_token_map],
          "Anthropic fallback credit token is invalid"
        )
    end
  end

  defp validate_model_features(model, opts) do
    unsupported =
      for {param, true} <- [
            fallbacks:
              profile_extra(model, :server_side_fallbacks) == false and option(model, opts, :fallbacks) not in [nil, []],
            service_tier:
              profile_extra(model, :priority_tier) == false and
                option(model, opts, :service_tier) in [:priority, "priority"]
          ],
          do: param

    if unsupported == [], do: :ok, else: request_error(model.model, params: unsupported)
  end

  defp valid_fallback_credit_token?(nil), do: true

  defp valid_fallback_credit_token?(token) when is_binary(token),
    do: byte_size(token) in 1..2048

  defp valid_fallback_credit_token?(token) when is_map(token) do
    value = MapAccess.get(token, :token)
    mode = MapAccess.get(token, :mode)

    is_binary(value) and valid_fallback_credit_token?(value) and
      mode in [nil, :strict, "strict", :best_effort, "best_effort"]
  end

  defp valid_fallback_credit_token?(_token), do: false

  defp validate_compaction_params(model, opts, output_config) do
    case option(model, opts, :compaction) do
      nil ->
        :ok

      compaction when is_map(compaction) ->
        type = MapAccess.get(compaction, :type)
        instructions = MapAccess.get(compaction, :instructions)

        conflicts =
          for {option, true} <- [
                context_management: not is_nil(option(model, opts, :context_management)),
                stop_sequences: not is_nil(option(model, opts, :stop_sequences)) or Keyword.has_key?(opts, :stop),
                output_config: not is_nil(MapAccess.get(output_config, :format)),
                tool_choice: forced_tool_choice?(Keyword.get(opts, :tool_choice))
              ],
              do: option

        cond do
          type not in [:summarize, "summarize"] or
              (not is_nil(instructions) and
                 (not is_binary(instructions) or String.length(instructions) > 16_384)) ->
            compaction_error(model, [:compaction], :invalid_configuration)

          conflicts != [] ->
            compaction_error(model, [:compaction | conflicts], :incompatible_parameters)

          true ->
            :ok
        end

      _other ->
        compaction_error(model, [:compaction], :invalid_configuration)
    end
  end

  defp compaction_error(model, params, reason),
    do:
      request_error(model.model, [params: params, reason: reason], "Anthropic on-demand compaction request is invalid")

  defp adaptive_only_thinking_model?(model),
    do: profile_extra(model, :thinking_mode) in [:adaptive_only, "adaptive_only"]

  defp always_on_thinking_model?(model), do: profile_extra(model, :thinking_always_on) == true

  defp thinking_type(%{"type" => type}), do: type
  defp thinking_type(%{type: type}), do: type
  defp thinking_type(_thinking), do: nil

  # The effort a request names: the call's, then the model's, each from
  # `effort:`, `reasoning_effort:` (`effort:` wins when both are set) or
  # `output_config`'s `effort`.
  defp requested_effort(model, opts) do
    Keyword.get(opts, :effort) || Keyword.get(opts, :reasoning_effort) ||
      output_config_effort(Keyword.get(opts, :output_config)) ||
      Map.get(model, :effort) || Map.get(model, :reasoning_effort) ||
      output_config_effort(Map.get(model, :output_config))
  end

  # The effort a request runs at: the one it names, or the model's default.
  defp request_effort(model, opts),
    do: requested_effort(model, opts) || profile_value(model, :reasoning_effort_default)

  # The thinking a request sends: its `thinking`, or, when it names an effort
  # on a model that takes only adaptive thinking, adaptive thinking with its
  # summary shown.
  defp thinking(model, opts) do
    case option(model, opts, :thinking) do
      nil ->
        if adaptive_only_thinking_model?(model) and requested_effort(model, opts),
          do: %{"type" => "adaptive", "display" => "summarized"}

      thinking ->
        thinking
    end
  end

  # An effort the model's profile doesn't list fails before the request; a
  # profile without levels leaves the check to Anthropic.
  defp validate_effort(model, opts) do
    levels = profile_value(model, :reasoning_effort_levels) || []
    effort = requested_effort(model, opts)

    if is_nil(effort) or levels == [] or to_string(effort) in Enum.map(levels, &to_string/1) do
      :ok
    else
      request_error(
        model.model,
        [params: [:reasoning_effort], value: effort, supported: levels],
        "#{model.model} does not take reasoning effort #{effort}"
      )
    end
  end

  defp output_config_effort(%{"effort" => effort}), do: effort
  defp output_config_effort(%{effort: effort}), do: effort
  defp output_config_effort(_output_config), do: nil

  @effort_levels ~w(low medium high xhigh max)

  defp effort_rank(effort) when is_binary(effort) or is_atom(effort),
    do: Enum.find_index(@effort_levels, &(&1 == to_string(effort))) || -1

  defp effort_rank(_effort), do: -1

  defp server_tool_family(%{"type" => "web_fetch_" <> _version}), do: :web_fetch
  defp server_tool_family(%{"type" => "computer_20" <> _version}), do: :legacy_computer
  defp server_tool_family(_tool), do: nil

  defp tools(opts) do
    case Keyword.get(opts, :tools) do
      [_tool | _rest] = tools -> Tools.to_anthropic_tools(tools, strict: Keyword.get(opts, :strict))
      _none -> nil
    end
  end

  @doc false
  # Whether a call may force a tool call: some Claude models take only `:auto`
  # or `:none`, and others drop a forced choice while thinking.
  def forced_tool_choice?(model, opts) do
    modes = profile_extra(model, :tool_choice_modes)
    thinking? = thinking_enabled?(thinking(model, opts)) or always_on_thinking_model?(model)

    not (is_list(modes) and :any not in modes) and
      not (thinking? and profile_extra(model, :forced_tool_choice_with_thinking) != true)
  end

  defp tool_choice(model, opts) do
    choice = Keyword.get(opts, :tool_choice)

    if forced_tool_choice?(choice) and thinking_enabled?(thinking(model, opts)) and
         profile_extra(model, :forced_tool_choice_with_thinking) != true,
       do: nil,
       else: Tools.tool_choice(choice, parallel_tool_calls: option(model, opts, :parallel_tool_calls))
  end

  defp forced_tool_choice?(nil), do: false
  defp forced_tool_choice?(choice) when choice in [:any, "any", :required, "required"], do: true
  defp forced_tool_choice?(choice) when is_binary(choice), do: choice not in ["auto", "any", "none"]
  defp forced_tool_choice?(choice) when is_atom(choice), do: choice not in [:auto, :any, :none]
  defp forced_tool_choice?(%{"type" => type}), do: type in ["any", "tool"]
  defp forced_tool_choice?(%{type: type}), do: type in [:any, :tool, "any", "tool"]
  defp forced_tool_choice?(_choice), do: false

  defp thinking_enabled?(%{"type" => type}), do: type in ["enabled", "adaptive"]
  defp thinking_enabled?(%{type: type}), do: type in [:enabled, :adaptive, "enabled", "adaptive"]
  defp thinking_enabled?(_thinking), do: false

  # The call's settings override the model's, and within each, `effort:` (or
  # `reasoning_effort:`) overrides `output_config`'s `effort`.
  defp output_config(model, opts) do
    output_config =
      %{}
      |> Options.merge_optional_map(Map.get(model, :output_config))
      |> put_effort(Map.get(model, :effort) || Map.get(model, :reasoning_effort))
      |> Options.merge_optional_map(Keyword.get(opts, :output_config))
      |> put_effort(Keyword.get(opts, :effort) || Keyword.get(opts, :reasoning_effort))

    output_config =
      case Keyword.get(opts, :response_format) || Keyword.get(opts, :structured_output) do
        nil ->
          output_config

        format ->
          Map.put(output_config, "format", structured_output_format(format))
      end

    {:ok, Options.empty_to_nil(output_config)}
  rescue
    exception -> {:error, Error.new(:invalid_response_format, Exception.message(exception))}
  end

  defp structured_output_format(%{"type" => "json_schema", "schema" => _schema} = format), do: format

  defp structured_output_format(%{type: "json_schema", schema: _schema} = format),
    do: Options.stringify_keys(format)

  defp structured_output_format(format),
    do: %{"type" => "json_schema", "schema" => Options.stringify_keys(output_schema(format))}

  defp output_schema(%{"type" => "json_schema", "json_schema" => %{"schema" => schema}}), do: schema
  defp output_schema(%{type: "json_schema", json_schema: %{schema: schema}}), do: schema
  defp output_schema(%{"schema" => schema}) when is_map(schema), do: schema
  defp output_schema(%{schema: schema}) when is_map(schema), do: schema
  defp output_schema({_name, schema}) when is_map(schema), do: schema
  defp output_schema(schema) when is_map(schema), do: schema
  defp output_schema(_other), do: raise(ArgumentError, "Anthropic structured output requires a JSON schema map")

  defp put_effort(map, nil), do: map
  defp put_effort(map, effort), do: Map.put(map, "effort", Options.normalize_value(effort))

  defp betas(model, opts, tools, output_config, messages, fallbacks, fallback_credit_token) do
    tools = tools || []
    thinking = thinking(model, opts)
    blocks = Enum.flat_map(messages, &content_blocks/1)

    tools
    |> Tools.required_betas(option(model, opts, :betas) || [])
    |> maybe_add_beta(option(model, opts, :mcp_servers), "mcp-client-2025-11-20")
    |> maybe_add_beta(option(model, opts, :user_profile_id), "user-profiles-2026-08-18")
    |> maybe_add_beta(not is_nil(output_config["task_budget"]), "task-budgets-2026-03-13")
    |> maybe_add_beta(MapAccess.get(thinking, :display) in [:updates, "updates"], "thinking-display-updates-2026-08-18")
    |> maybe_add_beta(MapAccess.get(thinking, :block_binding), "thinking-binding-controls-2026-08-01")
    |> maybe_add_beta(
      block_type?(blocks, ["tool_addition", "tool_removal"]),
      "mid-conversation-tool-changes-2026-07-01"
    )
    |> maybe_upgrade_beta(
      inline_tool?(blocks, ["type"], "tool_definition"),
      "mid-conversation-tool-changes-2026-07-01",
      "inline-tools-2026-09-15"
    )
    |> maybe_upgrade_beta(
      block_type?(blocks, ["mcp_tool_listing"]) or inline_tool?(blocks, ["definition", "type"], "mcp_toolset") or
        pinned_mcp_toolset?(tools),
      "mcp-client-2025-11-20",
      "mcp-client-2026-09-15"
    )
    |> maybe_add_beta(option(model, opts, :compaction) || block_type?(blocks, ["compaction"]), "compact-2026-09-04")
    |> maybe_add_beta(system_message_field?(messages, "clear_at"), "mid-conversation-system-clear-at-2026-08-21")
    |> maybe_add_beta(system_message_field?(messages, "output_config"), "mid-conversation-output-config-2026-07-01")
    |> maybe_add_fallback_beta(fallbacks)
    |> maybe_add_beta(fallback_credit_token, "fallback-credit-2026-07-01")
  end

  defp maybe_add_beta(betas, value, _beta) when value in [nil, false, []], do: betas
  defp maybe_add_beta(betas, _value, beta), do: Enum.uniq(betas ++ [beta])

  defp maybe_upgrade_beta(betas, false, _old_beta, _new_beta), do: betas

  defp maybe_upgrade_beta(betas, true, old_beta, new_beta) do
    betas
    |> Enum.reject(&(&1 == old_beta))
    |> Kernel.++([new_beta])
    |> Enum.uniq()
  end

  defp maybe_add_fallback_beta(betas, fallback) when fallback in [:default, "default"] do
    betas
    |> Enum.reject(&(is_binary(&1) and String.starts_with?(&1, "server-side-fallback-")))
    |> Kernel.++(["server-side-fallback-2026-07-01"])
    |> Enum.uniq()
  end

  defp maybe_add_fallback_beta(betas, fallbacks) when is_list(fallbacks) and fallbacks != [] do
    if Enum.any?(betas, &(&1 in ["server-side-fallback-2026-06-01", "server-side-fallback-2026-07-01"])) do
      betas
    else
      betas ++ ["server-side-fallback-2026-06-01"]
    end
  end

  defp maybe_add_fallback_beta(betas, _fallbacks), do: betas

  defp block_type?(blocks, types), do: Enum.any?(blocks, &(&1["type"] in types))

  defp inline_tool?(blocks, path, type) do
    Enum.any?(blocks, fn block ->
      Enum.any?([block | List.wrap(block["tool_changes"])], &(get_in(&1, ["tool" | path]) == type))
    end)
  end

  defp pinned_mcp_toolset?(tools) do
    Enum.any?(tools, fn
      %{"type" => "mcp_toolset", "tools" => listing} when is_list(listing) -> true
      _tool -> false
    end)
  end

  defp content_blocks(%{"content" => content}) when is_list(content), do: Enum.filter(content, &is_map/1)
  defp content_blocks(_message), do: []

  defp system_message_field?(messages, field) do
    Enum.any?(messages, fn
      %{"role" => "system"} = message -> not is_nil(message[field])
      _message -> false
    end)
  end

  defp profile_extra(%{profile: %{extra: extra}}, key) when is_map(extra),
    do: MapAccess.get(extra, key)

  defp profile_extra(_model, _key), do: nil

  defp profile_value(%{profile: %BeamWeaver.Models.Profile{} = profile}, key), do: Map.get(profile, key)
  defp profile_value(_model, _key), do: nil

  defp maybe_put_container(body, model, messages, opts) do
    if Map.has_key?(body, "container") or !option(model, opts, :reuse_last_container),
      do: body,
      else: Options.put_optional(body, "container", last_container(messages))
  end

  defp last_container(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{role: :assistant, response_metadata: metadata} ->
        case metadata[:container] do
          %{"id" => id} when is_binary(id) -> id
          %{id: id} when is_binary(id) -> id
          _other -> nil
        end

      _message ->
        nil
    end)
  end

  # A call's `max_output_tokens` or `max_completion_tokens` is the same cap.
  defp max_tokens(model, opts) do
    Keyword.get(opts, :max_tokens) || Keyword.get(opts, :max_output_tokens) ||
      Keyword.get(opts, :max_completion_tokens) || model.max_tokens || profile_max_tokens(model) || 4096
  end

  defp profile_max_tokens(%{profile: %{max_output_tokens: value}}), do: value
  defp profile_max_tokens(_model), do: nil
end
