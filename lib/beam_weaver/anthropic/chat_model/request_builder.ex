defmodule BeamWeaver.Anthropic.ChatModel.RequestBuilder do
  @moduledoc false

  alias BeamWeaver.Anthropic.Error
  alias BeamWeaver.Anthropic.Messages
  alias BeamWeaver.Anthropic.Tools
  alias BeamWeaver.Models.ParamPolicy
  alias BeamWeaver.Provider.Options

  @supported_model_params [
    :betas,
    :cache_control,
    :container,
    :context_management,
    :diagnostics,
    :effort,
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

  @spec request_body(term(), [BeamWeaver.Core.Message.t()], keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def request_body(model, messages, opts \\ []) do
    with :ok <- validate_request_params(model, opts),
         :ok <- validate_sampling_params(model, opts),
         :ok <- validate_thinking_params(model, opts),
         {:ok, {system, formatted_messages}} <- Messages.format_messages(messages),
         {:ok, output_config} <- output_config(model, opts) do
      model_kwargs = option(model, opts, :model_kwargs) || %{}
      tools = tools(opts)
      betas = betas(model, opts, tools, output_config)

      body =
        %{
          "model" => Keyword.get(opts, :model, model.model),
          "max_tokens" => max_tokens(model, opts),
          "messages" => formatted_messages
        }
        |> Options.merge_extra_body(model_kwargs)
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
        |> Options.put_optional(
          "inference_geo",
          Options.normalize_value(option(model, opts, :inference_geo))
        )
        |> Options.put_optional("speed", Options.normalize_value(option(model, opts, :speed)))
        |> Options.put_optional("user_profile_id", option(model, opts, :user_profile_id))
        |> Options.put_optional("betas", betas)
        |> maybe_put_container(model, messages, opts)
        |> Options.merge_extra_body(Keyword.get(opts, :extra_body, %{}))

      {:ok, body}
    end
  end

  @spec count_tokens_body(term(), [BeamWeaver.Core.Message.t()], keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def count_tokens_body(model, messages, opts \\ []) do
    with :ok <- validate_thinking_params(model, opts),
         {:ok, {system, formatted_messages}} <- Messages.format_messages(messages),
         {:ok, output_config} <- output_config(model, opts) do
      tools = tools(opts)

      %{
        "model" => Keyword.get(opts, :model, model.model),
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
      |> Options.put_optional("betas", betas(model, opts, tools, output_config))
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
    if adaptive_only_thinking_model?(model) do
      case thinking_type(option(model, opts, :thinking)) do
        nil ->
          :ok

        type when type in [:adaptive, "adaptive", :disabled, "disabled"] ->
          :ok

        _type ->
          {:error,
           Error.new(:unsupported_model_param, "model parameter is not supported by profile", %{
             provider: :anthropic,
             model: model.model,
             params: [:thinking],
             reason: "This Claude model only supports adaptive thinking or disabled thinking"
           })}
      end
    else
      :ok
    end
  end

  defp restricted_sampling_model?(%{profile: %{extra: extra}, model: model}) when is_map(extra),
    do: Map.get(extra, :sampling_controls) == :restricted or opus_4_minor_at_least?(model, 7)

  defp restricted_sampling_model?(%{model: model}), do: opus_4_minor_at_least?(model, 7)

  defp restricted_sampling_model?(_model), do: false

  defp adaptive_only_thinking_model?(%{profile: %{extra: extra}, model: model}) when is_map(extra),
    do: Map.get(extra, :thinking_mode) == :adaptive_only or opus_4_minor_at_least?(model, 7)

  defp adaptive_only_thinking_model?(%{model: model}), do: opus_4_minor_at_least?(model, 7)

  defp adaptive_only_thinking_model?(_model), do: false

  defp thinking_type(%{"type" => type}), do: type
  defp thinking_type(%{type: type}), do: type
  defp thinking_type(_thinking), do: nil

  defp opus_4_minor_at_least?(model, minimum) when is_binary(model) do
    case Regex.run(~r/opus-4-(\d+)/, model) do
      [_, minor] -> String.to_integer(minor) >= minimum
      _other -> false
    end
  end

  defp opus_4_minor_at_least?(_model, _minimum), do: false

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

  defp tools(opts) do
    case Keyword.get(opts, :tools, []) do
      [] ->
        nil

      tools when is_list(tools) ->
        Tools.to_anthropic_tools(tools, strict: Keyword.get(opts, :strict))
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

  defp forced_tool_choice?(choice) when choice in [:any, "any"], do: true
  defp forced_tool_choice?(choice) when is_binary(choice), do: choice not in ["auto", "any"]
  defp forced_tool_choice?(choice) when is_atom(choice), do: choice not in [:auto, :any]
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

  defp betas(model, opts, tools, output_config) do
    base = option(model, opts, :betas) || []
    tools = tools || []

    Tools.required_betas(tools, base)
    |> maybe_add_beta(option(model, opts, :mcp_servers), "mcp-client-2025-11-20")
    |> maybe_add_beta(task_budget?(output_config), "task-budgets-2026-03-13")
    |> case do
      [] -> nil
      betas -> betas
    end
  end

  defp maybe_add_beta(betas, value, _beta) when value in [nil, false, []], do: betas
  defp maybe_add_beta(betas, _value, beta), do: Enum.uniq(betas ++ [beta])

  defp task_budget?(%{"task_budget" => task_budget}) when not is_nil(task_budget), do: true
  defp task_budget?(_output_config), do: false

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
