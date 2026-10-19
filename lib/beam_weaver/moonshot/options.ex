defmodule BeamWeaver.Moonshot.Options do
  @moduledoc false

  import BeamWeaver.Provider.Options,
    only: [
      extra_body: 2,
      merge_extra_body: 3,
      normalize_option_map: 1,
      normalize_value: 1,
      option: 3,
      put_optional: 3,
      stringify_keys: 1
    ]

  alias BeamWeaver.Models.ParamPolicy
  alias BeamWeaver.Models.ProfileRegistry
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Moonshot.Messages
  alias BeamWeaver.Provider.ChatCompletionsWire
  alias BeamWeaver.Provider.JsonObjectFormat

  @kimi_model_policies %{
    "kimi-k3" => %{
      thinking: :unsupported,
      reasoning_efforts: ["low", "high", "max"],
      tool_choice_when_thinking: ["auto", "none", "required"]
    },
    "kimi-k2.7-code" => %{
      thinking: :enabled_only,
      reasoning_efforts: [],
      tool_choice_when_thinking: ["auto", "none"]
    },
    "kimi-k2.7-code-highspeed" => %{
      thinking: :enabled_only,
      reasoning_efforts: [],
      tool_choice_when_thinking: ["auto", "none"]
    },
    "kimi-k2.6" => %{
      thinking: :toggle,
      reasoning_efforts: [],
      tool_choice_when_thinking: ["auto", "none"]
    }
  }

  # `extra_body` can't replace these: the client sets them for the call.
  @reserved_body_fields ["model", "messages", "stream"]

  @spec to_body(term(), [BeamWeaver.Core.Message.t()], keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def to_body(model, messages, opts) do
    with :ok <- validate_profile_params(model, opts),
         {:ok, moonshot_messages} <- Messages.to_chat_messages(messages),
         {:ok, response_format, instruction} <- response_format(model, opts),
         moonshot_messages = JsonObjectFormat.inject_instruction(moonshot_messages, instruction),
         :ok <- validate_partial_response_format(moonshot_messages, response_format),
         {:ok, body} <- build_body(model, moonshot_messages, response_format, opts),
         :ok <- validate_kimi_policy(body),
         :ok <- validate_stop(body["stop"]) do
      {:ok, body}
    end
  end

  @doc false
  # Kimi K2 models take `tool_choice: "required"` only with thinking disabled.
  def forced_tool_choice?(model, opts) do
    case Map.fetch(@kimi_model_policies, option(model, opts, :model)) do
      {:ok, policy} ->
        "required" in policy.tool_choice_when_thinking or
          (policy.thinking == :toggle and thinking_type(normalize_value(option(model, opts, :thinking))) == "disabled")

      :error ->
        true
    end
  end

  defp thinking_type(%{"type" => type}), do: type
  defp thinking_type(_thinking), do: nil

  defp build_body(model, messages, response_format, opts) do
    model_name = option(model, opts, :model)
    extra_body = extra_body(model, opts)

    body =
      %{
        "model" => model_name,
        "messages" => messages
      }
      |> put_optional("tool_choice", ChatCompletionsWire.tool_choice(option(model, opts, :tool_choice)))
      |> put_optional("response_format", response_format)
      |> put_optional("thinking", normalize_value(option(model, opts, :thinking)))
      |> put_optional(
        "reasoning_effort",
        normalize_value(option(model, opts, :reasoning_effort))
      )
      |> put_optional("temperature", option(model, opts, :temperature))
      |> put_optional("max_completion_tokens", max_completion_tokens(model, opts))
      |> put_optional("top_p", option(model, opts, :top_p))
      |> put_optional("frequency_penalty", option(model, opts, :frequency_penalty))
      |> put_optional("presence_penalty", option(model, opts, :presence_penalty))
      |> put_optional("n", option(model, opts, :n))
      |> put_optional("stop", Keyword.get(opts, :stop))
      |> put_optional("stream", Keyword.get(opts, :stream, false))
      |> put_optional("stream_options", normalize_option_map(Keyword.get(opts, :stream_options)))
      |> put_optional("prompt_cache_key", option(model, opts, :prompt_cache_key))
      |> put_optional("prompt_cache_options", normalize_option_map(option(model, opts, :prompt_cache_options)))
      |> put_optional("logprobs", option(model, opts, :logprobs))
      |> put_optional("top_logprobs", option(model, opts, :top_logprobs))
      |> put_optional("prediction", normalize_value(option(model, opts, :prediction)))
      |> put_optional("safety_identifier", option(model, opts, :safety_identifier))
      |> merge_extra_body(extra_body, reserved: @reserved_body_fields)

    # Deprecated OpenAI params these APIs reject even through `extra_body`.
    rejected = for key <- Map.keys(extra_body), key in ["functions", "function_call"], do: String.to_atom(key)

    if rejected == [],
      do: {:ok, body},
      else:
        error(:unsupported_model_param, "Moonshot does not support deprecated OpenAI params",
          model: model_name,
          params: rejected
        )
  end

  # Returns the wire format and, for a model that ignores JSON Schema
  # formats (the profile's `json_mode_only`, such as Kimi K2.6), the system
  # instruction that carries the schema with JSON mode instead.
  defp response_format(model, opts) do
    format = option(model, opts, :response_format) || option(model, opts, :structured_output)

    with {:ok, format} <- wire_response_format(format) do
      case format do
        %{"type" => "json_schema", "json_schema" => %{"name" => name, "schema" => schema} = spec} ->
          if json_mode_only?(model, opts),
            do: JsonObjectFormat.normalize(%{"name" => name, "schema" => schema, "strict" => spec["strict"]}),
            else: {:ok, format, nil}

        format ->
          {:ok, format, nil}
      end
    end
  end

  defp wire_response_format(nil), do: {:ok, nil}
  defp wire_response_format(%{"type" => _type} = format), do: {:ok, format}
  defp wire_response_format(%{type: type} = format) when is_binary(type), do: {:ok, stringify_keys(format)}

  defp wire_response_format(%{type: type} = format) when is_atom(type),
    do: {:ok, format |> Map.put(:type, Atom.to_string(type)) |> stringify_keys()}

  defp wire_response_format(%{name: name, schema: schema} = format) when is_binary(name) and is_map(schema),
    do: {:ok, Messages.structured_output_format(name, schema, strict: Map.get(format, :strict, true))}

  defp wire_response_format(%{"name" => name, "schema" => schema} = format) when is_binary(name) and is_map(schema),
    do: {:ok, Messages.structured_output_format(name, schema, strict: Map.get(format, "strict", true))}

  defp wire_response_format({name, schema}) when is_binary(name) and is_map(schema),
    do: {:ok, Messages.structured_output_format(name, schema)}

  defp wire_response_format(other) do
    {:error,
     Error.new(:invalid_response_format, "structured output requires a name and schema", %{
       response_format: inspect(other)
     })}
  end

  defp json_mode_only?(model, opts) do
    profile =
      case option(model, opts, :model) do
        name when name == model.model -> model.profile
        name -> with {:ok, profile} <- ProfileRegistry.fetch(:moonshot, name), do: profile
      end

    match?(%{extra: %{json_mode_only: true}}, profile)
  end

  defp validate_profile_params(model, opts) do
    params =
      model
      |> Map.from_struct()
      |> Map.take([
        :frequency_penalty,
        :max_completion_tokens,
        :max_output_tokens,
        :max_tokens,
        :n,
        :presence_penalty,
        :prompt_cache_key,
        :prompt_cache_options,
        :logprobs,
        :top_logprobs,
        :prediction,
        :reasoning_effort,
        :response_format,
        :safety_identifier,
        :stream_usage,
        :structured_output,
        :temperature,
        :thinking,
        :tool_choice,
        :top_p
      ])
      |> Map.merge(Map.new(opts))

    ParamPolicy.validate(Map.get(model, :profile), params, option(model, opts, :param_policy), api: :chat_completions)
  end

  defp error(type, message, details),
    do: {:error, Error.new(type, message, Enum.into(details, %{provider: :moonshot}))}

  defp validate_partial_response_format(messages, %{"type" => "json_object"}) do
    if Enum.any?(messages, &(&1["role"] == "assistant" and &1["partial"] == true)),
      do: error(:invalid_request, "Moonshot partial mode cannot be combined with JSON object mode", feature: :partial),
      else: :ok
  end

  defp validate_partial_response_format(_messages, _response_format), do: :ok

  defp validate_kimi_policy(%{"model" => model_name} = body) do
    case Map.fetch(@kimi_model_policies, model_name) do
      {:ok, policy} ->
        with :ok <- validate_kimi_thinking(body, policy),
             :ok <- validate_kimi_reasoning_effort(body, policy),
             :ok <- validate_kimi_tool_choice(body, policy) do
          validate_kimi_sampling(body, policy)
        end

      :error ->
        :ok
    end
  end

  defp validate_kimi_thinking(%{"model" => model_name} = body, %{thinking: :unsupported}) do
    case Map.get(body, "thinking") do
      nil ->
        :ok

      value ->
        error(:unsupported_model_param, "Moonshot Kimi model does not accept thinking",
          model: model_name,
          param: :thinking,
          value: value,
          supported: []
        )
    end
  end

  defp validate_kimi_thinking(%{"model" => model_name} = body, %{thinking: :enabled_only}) do
    case get_in(body, ["thinking", "type"]) do
      type when type in [nil, "enabled"] ->
        :ok

      value ->
        error(:unsupported_model_param, "Moonshot Kimi model requires thinking mode",
          model: model_name,
          param: :thinking,
          value: %{"type" => value},
          supported: [%{"type" => "enabled"}]
        )
    end
  end

  defp validate_kimi_thinking(%{"model" => model_name} = body, %{thinking: :toggle}) do
    case get_in(body, ["thinking", "type"]) do
      type when type in [nil, "enabled", "disabled"] ->
        :ok

      value ->
        error(:unsupported_model_param, "Moonshot Kimi model received unsupported thinking mode",
          model: model_name,
          param: :thinking,
          value: %{"type" => value},
          supported: [%{"type" => "enabled"}, %{"type" => "disabled"}]
        )
    end
  end

  defp validate_kimi_reasoning_effort(%{"model" => model_name} = body, policy) do
    effort = Map.get(body, "reasoning_effort")

    if is_nil(effort) or effort in policy.reasoning_efforts do
      :ok
    else
      error(:unsupported_model_param, "Moonshot Kimi model received unsupported reasoning_effort",
        model: model_name,
        param: :reasoning_effort,
        value: effort,
        supported: policy.reasoning_efforts
      )
    end
  end

  defp validate_kimi_tool_choice(%{"model" => model_name} = body, policy) do
    thinking_type = get_in(body, ["thinking", "type"]) || "enabled"
    tool_choice = Map.get(body, "tool_choice")
    supported = policy.tool_choice_when_thinking

    # With thinking disabled, every tool choice is accepted.
    if thinking_type == "disabled" or is_nil(tool_choice) or tool_choice in supported do
      :ok
    else
      error(:unsupported_model_param, "Moonshot Kimi model supports only the documented tool choices",
        model: model_name,
        param: :tool_choice,
        value: tool_choice,
        supported: supported
      )
    end
  end

  defp validate_kimi_sampling(body, policy) do
    temperature =
      if policy.thinking == :toggle and get_in(body, ["thinking", "type"]) == "disabled", do: 0.6, else: 1.0

    Enum.find_value(
      [{"temperature", temperature}, {"top_p", 0.95}, {"n", 1}, {"presence_penalty", 0}, {"frequency_penalty", 0}],
      :ok,
      fn {key, expected} -> with :ok <- validate_fixed_number(body, key, expected), do: nil end
    )
  end

  defp validate_fixed_number(body, key, expected) do
    case Map.get(body, key) do
      nil ->
        :ok

      value when is_number(value) and abs(value * 1.0 - expected * 1.0) < 1.0e-9 ->
        :ok

      value ->
        error(:unsupported_model_param, "Moonshot Kimi model uses fixed sampling params",
          model: body["model"],
          param: fixed_param(key),
          value: value,
          supported: expected
        )
    end
  end

  defp fixed_param("temperature"), do: :temperature
  defp fixed_param("top_p"), do: :top_p
  defp fixed_param(key), do: key

  defp validate_stop(nil), do: :ok
  defp validate_stop(stop) when is_binary(stop) and byte_size(stop) <= 32, do: :ok

  defp validate_stop(stop) when is_list(stop) and length(stop) > 5,
    do: error(:invalid_request, "Moonshot stop supports at most 5 sequences", count: length(stop), max: 5)

  defp validate_stop(stop) when is_list(stop),
    do: Enum.find_value(stop, :ok, fn sequence -> with :ok <- validate_stop(sequence), do: nil end)

  defp validate_stop(stop),
    do: error(:invalid_request, "Moonshot stop sequences must be strings of at most 32 bytes", stop: inspect(stop))

  defp max_completion_tokens(model, opts) do
    option(model, opts, :max_completion_tokens) ||
      option(model, opts, :max_output_tokens) ||
      option(model, opts, :max_tokens)
  end
end
