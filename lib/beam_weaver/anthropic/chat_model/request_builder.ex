defmodule BeamWeaver.Anthropic.ChatModel.RequestBuilder do
  @moduledoc false

  alias BeamWeaver.Anthropic.Error
  alias BeamWeaver.Anthropic.ChatModel.ModelResolution
  alias BeamWeaver.Anthropic.Messages
  alias BeamWeaver.Anthropic.Tools
  alias BeamWeaver.MapAccess
  alias BeamWeaver.Models.ParamPolicy
  alias BeamWeaver.Provider.Options

  @supported_model_params [
    :betas,
    :cache_control,
    :container,
    :context_management,
    :diagnostics,
    :effort,
    :fallbacks,
    :inference_geo,
    :max_tokens,
    :metadata,
    :mcp_servers,
    :model_kwargs,
    :output_config,
    :parallel_tool_calls,
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
    :user_profile_id
  ]

  @reserved_body_fields [
    :betas,
    :cache_control,
    :container,
    :context_management,
    :diagnostics,
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
    :user_profile_id
  ]

  @spec request_body(term(), [BeamWeaver.Core.Message.t()], keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def request_body(model, messages, opts \\ []) do
    with {:ok, model} <- ModelResolution.resolve(model, opts),
         :ok <- validate_request_params(model, opts),
         :ok <- validate_sampling_params(model, opts),
         :ok <- validate_thinking_params(model, opts),
         :ok <- validate_tool_compatibility(model, opts),
         {:ok, {system, formatted_messages}} <-
           Messages.format_messages(messages, message_format_opts(model)),
         :ok <- validate_final_turn(model, formatted_messages),
         {:ok, output_config} <- output_config(model, opts) do
      model_kwargs = option(model, opts, :model_kwargs) || %{}
      tools = tools(opts)
      fallbacks = option(model, opts, :fallbacks)
      betas = betas(model, opts, tools, output_config, formatted_messages, fallbacks)

      body =
        %{
          "model" => model.model,
          "max_tokens" => max_tokens(model, opts),
          "messages" => formatted_messages
        }
        |> Options.merge_extra_body(model_kwargs, reserved: @reserved_body_fields)
        |> Options.put_optional(
          "cache_control",
          Options.normalize_option_map(option(model, opts, :cache_control))
        )
        |> Options.put_optional("container", option(model, opts, :container))
        |> Options.put_optional("stream", Keyword.get(opts, :stream))
        |> Options.put_optional("system", system)
        |> Options.put_optional(
          "metadata",
          Options.normalize_option_map(option(model, opts, :metadata))
        )
        |> Options.put_optional("temperature", option(model, opts, :temperature))
        |> Options.put_optional("top_k", option(model, opts, :top_k))
        |> Options.put_optional("top_p", option(model, opts, :top_p))
        |> Options.put_optional(
          "stop_sequences",
          option(model, opts, :stop_sequences) || Keyword.get(opts, :stop)
        )
        |> Options.put_optional(
          "service_tier",
          Options.normalize_value(option(model, opts, :service_tier))
        )
        |> Options.put_optional("tools", tools)
        |> Options.put_optional("tool_choice", tool_choice(model, opts))
        |> Options.put_optional(
          "thinking",
          Options.normalize_option_map(option(model, opts, :thinking))
        )
        |> Options.put_optional("output_config", output_config)
        |> Options.put_optional(
          "context_management",
          Options.normalize_option_map(option(model, opts, :context_management))
        )
        |> Options.put_optional(
          "diagnostics",
          Options.normalize_option_map(option(model, opts, :diagnostics))
        )
        |> Options.put_optional(
          "mcp_servers",
          Options.normalize_option_list(option(model, opts, :mcp_servers))
        )
        |> Options.put_optional("fallbacks", normalize_fallbacks(fallbacks))
        |> Options.put_optional(
          "inference_geo",
          Options.normalize_value(option(model, opts, :inference_geo))
        )
        |> Options.put_optional("speed", Options.normalize_value(option(model, opts, :speed)))
        |> Options.put_optional("user_profile_id", option(model, opts, :user_profile_id))
        |> Options.put_optional("betas", betas)
        |> maybe_put_container(model, messages, opts)
        |> Options.merge_extra_body(Keyword.get(opts, :extra_body, %{}),
          reserved: @reserved_body_fields
        )

      {:ok, body}
    end
  end

  @spec count_tokens_body(term(), [BeamWeaver.Core.Message.t()], keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def count_tokens_body(model, messages, opts \\ []) do
    with {:ok, model} <- ModelResolution.resolve(model, opts),
         :ok <- validate_thinking_params(model, opts),
         :ok <- validate_tool_compatibility(model, opts),
         {:ok, {system, formatted_messages}} <-
           Messages.format_messages(messages, message_format_opts(model)),
         :ok <- validate_final_turn(model, formatted_messages),
         {:ok, output_config} <- output_config(model, opts) do
      tools = tools(opts)

      %{
        "model" => model.model,
        "messages" => formatted_messages
      }
      |> Options.put_optional(
        "cache_control",
        Options.normalize_option_map(option(model, opts, :cache_control))
      )
      |> Options.put_optional("system", system)
      |> Options.put_optional("tools", tools)
      |> Options.put_optional("tool_choice", tool_choice(model, opts))
      |> Options.put_optional(
        "thinking",
        Options.normalize_option_map(option(model, opts, :thinking))
      )
      |> Options.put_optional("output_config", output_config)
      |> Options.put_optional(
        "context_management",
        Options.normalize_option_map(option(model, opts, :context_management))
      )
      |> Options.put_optional(
        "mcp_servers",
        Options.normalize_option_list(option(model, opts, :mcp_servers))
      )
      |> Options.put_optional("speed", Options.normalize_value(option(model, opts, :speed)))
      |> Options.put_optional(
        "betas",
        betas(model, opts, tools, output_config, formatted_messages, nil)
      )
      |> then(&{:ok, &1})
    end
  end

  defp validate_request_params(model, opts) do
    model_params =
      model
      |> Map.from_struct()
      |> Map.take(@supported_model_params)

    opts_params =
      opts
      |> Map.new()
      |> Map.take(@supported_model_params ++ [:extra_body, :provider_opts, :stop])

    params = Map.merge(model_params, opts_params)
    policy = Keyword.get(opts, :param_policy, model.param_policy)

    case ParamPolicy.validate(model.profile, params, policy, metadata: Keyword.get(opts, :metadata, %{})) do
      :ok -> :ok
      {:error, error} -> {:error, Error.new(error.type, error.message, error.details)}
    end
  end

  defp validate_sampling_params(model, opts) do
    if restricted_sampling_model?(model) do
      unsupported =
        [
          restricted_temperature_param(model, opts),
          restricted_top_k_param(model, opts),
          restricted_top_p_param(model, opts)
        ]
        |> Enum.reject(&is_nil/1)

      case unsupported do
        [] ->
          :ok

        params ->
          {:error,
           Error.new(:unsupported_model_param, "model parameter is not supported by profile", %{
             provider: :anthropic,
             model: model.model,
             params: params,
             reason: "Anthropic restricts temperature, top_k, and top_p for this Claude model"
           })}
      end
    else
      :ok
    end
  end

  defp validate_thinking_params(model, opts) do
    with :ok <- validate_thinking_shape(model, opts),
         :ok <- validate_thinking_mode(model, opts),
         :ok <- validate_disabled_thinking_effort(model, opts) do
      validate_thinking_block_binding(model, opts)
    end
  end

  defp validate_thinking_shape(model, opts) do
    case option(model, opts, :thinking) do
      thinking when is_nil(thinking) or is_map(thinking) ->
        :ok

      thinking ->
        {:error,
         Error.new(:unsupported_model_param, "model parameter has an invalid shape", %{
           provider: :anthropic,
           model: model.model,
           params: [:thinking],
           expected: :map,
           value: inspect(thinking)
         })}
    end
  end

  defp validate_thinking_mode(model, opts) do
    thinking_type = thinking_type(option(model, opts, :thinking))

    cond do
      always_on_thinking_model?(model) and thinking_type in [:disabled, "disabled"] ->
        {:error,
         Error.new(:unsupported_model_param, "model parameter is not supported by profile", %{
           provider: :anthropic,
           model: model.model,
           params: [:thinking],
           reason: "Thinking is always on for this Claude model"
         })}

      not adaptive_only_thinking_model?(model) ->
        :ok

      is_nil(thinking_type) or thinking_type in [:adaptive, "adaptive", :disabled, "disabled"] ->
        :ok

      true ->
        {:error,
         Error.new(:unsupported_model_param, "model parameter is not supported by profile", %{
           provider: :anthropic,
           model: model.model,
           params: [:thinking],
           reason: "This Claude model only supports adaptive thinking or disabled thinking"
         })}
    end
  end

  defp validate_disabled_thinking_effort(model, opts) do
    thinking_type = thinking_type(option(model, opts, :thinking))
    max_effort = profile_extra(model, :thinking_disabled_max_effort)
    effort = request_effort(model, opts)

    if thinking_type in [:disabled, "disabled"] and effort_above?(effort, max_effort) do
      {:error,
       Error.new(:unsupported_model_param, "model parameter is not supported by profile", %{
         provider: :anthropic,
         model: model.model,
         params: [:thinking, :effort],
         reason: "Thinking can only be disabled at #{max_effort} effort or below"
       })}
    else
      :ok
    end
  end

  defp validate_thinking_block_binding(model, opts) do
    case thinking_block_binding(option(model, opts, :thinking)) do
      nil ->
        :ok

      binding when is_map(binding) ->
        if thinking_binding_behavior(binding) in [:error, "error", :drop_block, "drop_block"] do
          :ok
        else
          thinking_block_binding_error(model)
        end

      _binding ->
        thinking_block_binding_error(model)
    end
  end

  defp thinking_block_binding_error(model) do
    {:error,
     Error.new(:unsupported_model_param, "model parameter is not supported by profile", %{
       provider: :anthropic,
       model: model.model,
       params: [:thinking],
       field: "thinking.block_binding.prefix_mismatch_behavior",
       supported: [:error, :drop_block]
     })}
  end

  defp validate_tool_compatibility(model, opts) do
    with :ok <- validate_tool_choice_compatibility(model, opts) do
      validate_server_tool_compatibility(model, opts)
    end
  end

  defp validate_final_turn(model, messages) do
    if rejects_prefilled_model_turns?(model) and final_assistant_turn?(messages) do
      {:error,
       Error.new(:invalid_message, "Anthropic model requests cannot end with an assistant turn", %{
         provider: :anthropic,
         model: model.model,
         role: :assistant,
         requirement: :final_user_tool_or_system_turn
       })}
    else
      :ok
    end
  end

  defp rejects_prefilled_model_turns?(model),
    do: profile_extra(model, :prefilled_model_turns) == false

  defp final_assistant_turn?(messages) do
    case List.last(messages) do
      %{"role" => "assistant"} -> true
      _message -> false
    end
  end

  defp validate_tool_choice_compatibility(model, opts) do
    supported = profile_extra(model, :tool_choice_modes)
    choice = Keyword.get(opts, :tool_choice)

    if is_list(supported) and forced_tool_choice?(choice) do
      {:error,
       Error.new(:unsupported_model_param, "model parameter is not supported by profile", %{
         provider: :anthropic,
         model: model.model,
         params: [:tool_choice],
         reason: "This Claude model supports only auto or none tool choice",
         supported: supported
       })}
    else
      :ok
    end
  end

  defp validate_server_tool_compatibility(model, opts) do
    unsupported = profile_extra(model, :unsupported_server_tools) || []

    requested_unsupported =
      opts
      |> tools()
      |> List.wrap()
      |> Enum.map(&server_tool_family/1)
      |> Enum.filter(&(&1 in unsupported))
      |> Enum.uniq()

    case requested_unsupported do
      [] ->
        :ok

      server_tools ->
        {:error,
         Error.new(:unsupported_feature, "server tool is not supported by model", %{
           provider: :anthropic,
           model: model.model,
           params: [:tools],
           unsupported_server_tools: server_tools
         })}
    end
  end

  defp restricted_sampling_model?(model),
    do: profile_extra(model, :sampling_controls) in [:restricted, "restricted"]

  defp adaptive_only_thinking_model?(model),
    do: profile_extra(model, :thinking_mode) in [:adaptive_only, "adaptive_only"]

  defp always_on_thinking_model?(model), do: profile_extra(model, :thinking_always_on) == true

  defp thinking_type(%{"type" => type}), do: type
  defp thinking_type(%{type: type}), do: type
  defp thinking_type(_thinking), do: nil

  defp thinking_block_binding(thinking), do: MapAccess.get(thinking, :block_binding)

  defp thinking_binding_behavior(binding), do: MapAccess.get(binding, :prefix_mismatch_behavior)

  defp request_effort(model, opts) do
    option(model, opts, :effort) ||
      output_config_effort(Keyword.get(opts, :output_config)) ||
      output_config_effort(Map.get(model, :output_config)) ||
      profile_extra(model, :default_effort)
  end

  defp output_config_effort(%{"effort" => effort}), do: effort
  defp output_config_effort(%{effort: effort}), do: effort
  defp output_config_effort(_output_config), do: nil

  defp effort_above?(_effort, nil), do: false

  defp effort_above?(effort, maximum) do
    effort_rank(effort) > effort_rank(maximum)
  end

  defp effort_rank(effort) when is_binary(effort) do
    case effort do
      "low" -> 0
      "medium" -> 1
      "high" -> 2
      "xhigh" -> 3
      "max" -> 4
      _other -> -1
    end
  end

  defp effort_rank(effort) when is_atom(effort), do: effort |> Atom.to_string() |> effort_rank()
  defp effort_rank(_effort), do: -1

  defp restricted_temperature_param(model, opts) do
    case option(model, opts, :temperature) do
      nil -> nil
      1 -> nil
      1.0 -> nil
      _value -> :temperature
    end
  end

  defp restricted_top_k_param(model, opts) do
    case option(model, opts, :top_k) do
      nil -> nil
      _value -> :top_k
    end
  end

  defp restricted_top_p_param(model, opts) do
    case option(model, opts, :top_p) do
      nil -> nil
      value when is_number(value) and value >= 0.99 -> nil
      _value -> :top_p
    end
  end

  defp server_tool_family(%{"type" => "web_fetch_" <> _version}), do: :web_fetch
  defp server_tool_family(%{type: "web_fetch_" <> _version}), do: :web_fetch
  defp server_tool_family(_tool), do: nil

  defp tools(opts) do
    case Keyword.get(opts, :tools, []) do
      [] ->
        nil

      tools when is_list(tools) ->
        Tools.to_anthropic_tools(tools, strict: Keyword.get(opts, :strict))

      _other ->
        nil
    end
  end

  defp tool_choice(model, opts) do
    choice = Keyword.get(opts, :tool_choice)
    parallel = Keyword.get(opts, :parallel_tool_calls, Map.get(model, :parallel_tool_calls))
    thinking = option(model, opts, :thinking)

    if forced_tool_choice?(choice) and thinking_enabled?(thinking) do
      nil
    else
      Tools.tool_choice(choice, parallel_tool_calls: parallel)
    end
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

  defp output_config(model, opts) do
    output_config =
      %{}
      |> Options.merge_optional_map(option(model, opts, :output_config))
      |> Options.merge_optional_map(Keyword.get(opts, :output_config))
      |> put_effort(option(model, opts, :effort))

    output_config =
      case Keyword.get(opts, :response_format) || Keyword.get(opts, :structured_output) do
        nil ->
          output_config

        format ->
          Map.put(output_config, "format", structured_output_format(format))
      end

    {:ok, if(output_config == %{}, do: nil, else: output_config)}
  rescue
    exception -> {:error, Error.new(:invalid_response_format, Exception.message(exception))}
  end

  defp structured_output_format(%{"type" => "json_schema", "schema" => _schema} = format),
    do: format

  defp structured_output_format(%{type: "json_schema", schema: _schema} = format),
    do: Options.stringify_keys(format)

  defp structured_output_format(%{
         "type" => "json_schema",
         "json_schema" => %{"schema" => schema}
       }),
       do: %{"type" => "json_schema", "schema" => Options.stringify_keys(schema)}

  defp structured_output_format(%{type: "json_schema", json_schema: %{schema: schema}}),
    do: %{"type" => "json_schema", "schema" => Options.stringify_keys(schema)}

  defp structured_output_format(%{"schema" => schema}) when is_map(schema),
    do: %{"type" => "json_schema", "schema" => Options.stringify_keys(schema)}

  defp structured_output_format(%{schema: schema}) when is_map(schema),
    do: %{"type" => "json_schema", "schema" => Options.stringify_keys(schema)}

  defp structured_output_format({_name, schema}) when is_map(schema),
    do: %{"type" => "json_schema", "schema" => Options.stringify_keys(schema)}

  defp structured_output_format(schema) when is_map(schema),
    do: %{"type" => "json_schema", "schema" => Options.stringify_keys(schema)}

  defp structured_output_format(_other),
    do: raise(ArgumentError, "Anthropic structured output requires a JSON schema map")

  defp put_effort(map, nil), do: map
  defp put_effort(map, effort), do: Map.put(map, "effort", Options.normalize_value(effort))

  defp betas(model, opts, tools, output_config, messages, fallbacks) do
    base = option(model, opts, :betas) || []
    tools = tools || []

    Tools.required_betas(tools, base)
    |> maybe_add_beta(option(model, opts, :mcp_servers), "mcp-client-2025-11-20")
    |> maybe_add_beta(task_budget?(output_config), "task-budgets-2026-03-13")
    |> maybe_add_beta(
      thinking_block_binding(option(model, opts, :thinking)),
      "thinking-binding-controls-2026-08-01"
    )
    |> maybe_add_beta(tool_changes?(messages), "mid-conversation-tool-changes-2026-07-01")
    |> maybe_add_fallback_beta(fallbacks)
    |> case do
      [] -> nil
      betas -> betas
    end
  end

  defp maybe_add_beta(betas, value, _beta) when value in [nil, false, []], do: betas
  defp maybe_add_beta(betas, _value, beta), do: Enum.uniq(betas ++ [beta])

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

  defp task_budget?(%{"task_budget" => task_budget}) when not is_nil(task_budget), do: true
  defp task_budget?(_output_config), do: false

  defp tool_changes?(messages) do
    Enum.any?(messages, fn
      %{"content" => content} when is_list(content) ->
        Enum.any?(content, fn
          %{"type" => type} -> type in ["tool_addition", "tool_removal"]
          _block -> false
        end)

      _message ->
        false
    end)
  end

  defp normalize_fallbacks(fallbacks) when fallbacks in [nil, []], do: nil
  defp normalize_fallbacks(fallbacks) when is_list(fallbacks), do: Options.normalize_option_list(fallbacks)
  defp normalize_fallbacks(fallbacks), do: Options.normalize_value(fallbacks)

  defp message_format_opts(model) do
    [
      mid_conversation_system_messages: profile_extra(model, :mid_conversation_system_messages) == true
    ]
  end

  defp profile_extra(%{profile: %{extra: extra}}, key) when is_map(extra),
    do: MapAccess.get(extra, key)

  defp profile_extra(_model, _key), do: nil

  defp maybe_put_container(body, model, messages, opts) do
    if Map.has_key?(body, "container") do
      body
    else
      maybe_put_reused_container(body, model, messages, opts)
    end
  end

  defp maybe_put_reused_container(body, model, messages, opts) do
    if Keyword.get(opts, :reuse_last_container, model.reuse_last_container) do
      case last_container(messages) do
        nil -> body
        container_id -> Map.put(body, "container", container_id)
      end
    else
      body
    end
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

  defp max_tokens(model, opts) do
    Keyword.get(opts, :max_tokens, model.max_tokens || profile_max_tokens(model) || 4096)
  end

  defp profile_max_tokens(%{profile: %{max_output_tokens: value}}), do: value
  defp profile_max_tokens(_model), do: nil

  defp option(model, opts, key), do: Keyword.get(opts, key, Map.get(model, key))
end
