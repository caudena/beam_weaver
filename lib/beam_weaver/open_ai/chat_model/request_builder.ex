defmodule BeamWeaver.OpenAI.ChatModel.RequestBuilder do
  @moduledoc false

  alias BeamWeaver.Models.ParamPolicy
  alias BeamWeaver.OpenAI.ChatModel.StructuredOutput
  alias BeamWeaver.OpenAI.Messages
  alias BeamWeaver.OpenAI.ModelPolicy
  alias BeamWeaver.OpenAI.ToolCalling
  alias BeamWeaver.Provider.Options

  def request_body(model, messages, opts \\ []) do
    {messages, previous_response_id} = previous_response_context(messages, opts)

    store = effective_store(model, opts)

    with :ok <- validate_request_params(model, opts),
         {:ok, message_input} <- Messages.to_responses_input(messages, store: store),
         {:ok, input_items} <- Messages.normalize_input_items(Keyword.get(opts, :input_items)),
         {:ok, structured_output} <- StructuredOutput.format(opts) do
      input = message_input ++ input_items
      model_name = Keyword.get(opts, :model, model.model)
      model_kwargs = option(model, opts, :model_kwargs) || %{}
      reasoning = reasoning_option(model, opts)
      text = text_option(model, opts, model_kwargs, structured_output)

      body =
        %{
          "model" => model_name,
          "input" => input,
          "stream" => Keyword.get(opts, :stream, false)
        }
        |> merge_model_kwargs(model_kwargs)
        |> Options.put_optional("tools", tools(opts))
        |> Options.put_optional("text", text)
        |> Options.put_optional("reasoning", reasoning)
        |> Options.put_optional(
          "temperature",
          temperature_option(model_name, model, opts, reasoning)
        )
        |> Options.put_optional("max_output_tokens", max_output_tokens_option(model, opts))
        |> Options.put_optional("top_p", option(model, opts, :top_p))
        |> Options.put_optional("frequency_penalty", option(model, opts, :frequency_penalty))
        |> Options.put_optional("presence_penalty", option(model, opts, :presence_penalty))
        |> Options.put_optional("seed", option(model, opts, :seed))
        |> Options.put_optional("parallel_tool_calls", option(model, opts, :parallel_tool_calls))
        |> Options.put_optional(
          "metadata",
          Options.normalize_option_map(option(model, opts, :metadata))
        )
        |> Options.put_optional("user", option(model, opts, :user))
        |> Options.put_optional(
          "service_tier",
          Options.normalize_value(option(model, opts, :service_tier))
        )
        |> Options.put_optional("modalities", option(model, opts, :modalities))
        |> Options.put_optional(
          "audio",
          Options.normalize_option_map(option(model, opts, :audio))
        )
        |> Options.put_optional("store", option(model, opts, :store))
        |> Options.put_optional("background", Keyword.get(opts, :background))
        |> Options.put_optional(
          "conversation",
          Options.normalize_value(Keyword.get(opts, :conversation))
        )
        |> Options.put_optional("include", Keyword.get(opts, :include))
        |> Options.put_optional("instructions", Keyword.get(opts, :instructions))
        |> Options.put_optional("max_tool_calls", Keyword.get(opts, :max_tool_calls))
        |> Options.put_optional("max_turns", option(model, opts, :max_turns))
        |> Options.put_optional("previous_response_id", previous_response_id)
        |> Options.put_optional("prompt", Options.normalize_value(Keyword.get(opts, :prompt)))
        |> put_explicit_optional("prompt_cache_key", opts, :prompt_cache_key)
        |> Options.put_optional(
          "prompt_cache_retention",
          Options.normalize_value(option(model, opts, :prompt_cache_retention))
        )
        |> Options.put_optional("safety_identifier", Keyword.get(opts, :safety_identifier))
        |> Options.put_optional(
          "stream_options",
          Options.normalize_option_map(Keyword.get(opts, :stream_options))
        )
        |> Options.put_optional("top_logprobs", Keyword.get(opts, :top_logprobs))
        |> Options.put_optional(
          "context_management",
          Options.normalize_option_list(Keyword.get(opts, :context_management))
        )
        |> Options.put_optional("logprobs", option(model, opts, :logprobs))
        |> Options.put_optional(
          "search_parameters",
          Options.normalize_value(option(model, opts, :search_parameters))
        )
        |> Options.put_optional(
          "tool_choice",
          Options.normalize_value(Keyword.get(opts, :tool_choice))
        )
        |> Options.put_optional("truncation", Keyword.get(opts, :truncation))
        |> Options.merge_extra_body(Keyword.get(opts, :extra_body, %{}))

      {:ok, body}
    end
  end

  defp previous_response_context(messages, opts) do
    explicit_id = Keyword.get(opts, :previous_response_id)

    cond do
      not is_nil(explicit_id) ->
        {messages, explicit_id}

      Keyword.get(opts, :use_previous_response_id) == true ->
        Messages.last_after_previous_response(messages)

      true ->
        {messages, nil}
    end
  end

  defp validate_request_params(model, opts) do
    model_params =
      model
      |> Map.from_struct()
      |> Map.take([
        :audio,
        :deferred,
        :frequency_penalty,
        :logprobs,
        :max_completion_tokens,
        :max_output_tokens,
        :max_tokens,
        :max_turns,
        :metadata,
        :modalities,
        :model_kwargs,
        :parallel_tool_calls,
        :prompt,
        :prompt_cache_key,
        :prompt_cache_retention,
        :presence_penalty,
        :reasoning,
        :reasoning_effort,
        :safety_identifier,
        :search_parameters,
        :seed,
        :service_tier,
        :store,
        :temperature,
        :top_p,
        :user,
        :verbosity
      ])

    opts_params =
      opts
      |> Map.new()
      |> Map.take([
        :audio,
        :background,
        :conversation,
        :context_management,
        :deferred,
        :extra_body,
        :frequency_penalty,
        :include,
        :instructions,
        :max_tool_calls,
        :max_completion_tokens,
        :max_output_tokens,
        :max_tokens,
        :max_turns,
        :metadata,
        :modalities,
        :model_kwargs,
        :parallel_tool_calls,
        :prompt,
        :prompt_cache_key,
        :prompt_cache_retention,
        :presence_penalty,
        :previous_response_id,
        :provider_opts,
        :reasoning,
        :reasoning_effort,
        :response_format,
        :safety_identifier,
        :search_parameters,
        :seed,
        :service_tier,
        :store,
        :stream,
        :stream_options,
        :text,
        :structured_output,
        :temperature,
        :tool_choice,
        :tools,
        :logprobs,
        :top_logprobs,
        :top_p,
        :truncation,
        :use_previous_response_id,
        :user,
        :verbosity
      ])

    params = Map.merge(model_params, opts_params)
    policy = Keyword.get(opts, :param_policy, model.param_policy)

    ParamPolicy.validate(model.profile, params, policy,
      api: :responses,
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  defp tools(opts) do
    case Keyword.get(opts, :tools, []) do
      [] -> nil
      tools when is_list(tools) -> tools |> ToolCalling.to_openai_tools() |> streaming_tools(opts)
    end
  end

  defp streaming_tools(tools, opts) do
    if Keyword.get(opts, :stream, false) do
      Enum.map(tools, &streaming_tool/1)
    else
      tools
    end
  end

  defp streaming_tool(%{"type" => "image_generation"} = tool) do
    Map.put_new(tool, "partial_images", 1)
  end

  defp streaming_tool(tool), do: tool

  defp put_explicit_optional(body, key, opts, opt_key) do
    if Keyword.has_key?(opts, opt_key) do
      Map.put(body, key, Keyword.get(opts, opt_key))
    else
      body
    end
  end

  defp option(model, opts, key), do: Keyword.get(opts, key, Map.get(model, key))

  defp effective_store(model, opts) do
    case Keyword.get(opts, :extra_body, %{}) do
      %{store: store} -> store
      %{"store" => store} -> store
      _extra_body -> option(model, opts, :store)
    end
  end

  defp merge_model_kwargs(body, model_kwargs) when map_size(model_kwargs) == 0, do: body

  defp merge_model_kwargs(body, model_kwargs) when is_map(model_kwargs),
    do: Map.merge(body, Options.stringify_keys(model_kwargs))

  defp reasoning_option(model, opts) do
    case option(model, opts, :reasoning) do
      nil ->
        case option(model, opts, :reasoning_effort) do
          nil -> nil
          effort -> %{"effort" => Options.normalize_value(effort)}
        end

      reasoning ->
        Options.normalize_option_map(reasoning)
    end
  end

  defp text_option(model, opts, model_kwargs, structured_output) do
    explicit_text = Keyword.get(opts, :text) |> Options.normalize_option_map()

    model_kwargs_text =
      model_kwargs
      |> Options.stringify_keys()
      |> Map.get("text")
      |> Options.normalize_option_map()

    %{}
    |> Options.merge_optional_map(explicit_text)
    |> Options.merge_optional_map(model_kwargs_text)
    |> Options.merge_optional_map(structured_output)
    |> Options.put_optional("verbosity", Options.normalize_value(option(model, opts, :verbosity)))
    |> Options.empty_to_nil()
  end

  defp max_output_tokens_option(model, opts) do
    option(model, opts, :max_output_tokens) ||
      option(model, opts, :max_completion_tokens) ||
      option(model, opts, :max_tokens)
  end

  defp temperature_option(model_name, model, opts, reasoning) do
    ModelPolicy.request_temperature(model_name, option(model, opts, :temperature), reasoning)
  end
end
