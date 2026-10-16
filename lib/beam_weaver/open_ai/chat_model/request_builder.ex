defmodule BeamWeaver.OpenAI.ChatModel.RequestBuilder do
  @moduledoc false

  alias BeamWeaver.Models.ParamPolicy
  alias BeamWeaver.OpenAI.ChatModel.StructuredOutput
  alias BeamWeaver.Core.Error
  alias BeamWeaver.OpenAI.Messages
  alias BeamWeaver.OpenAI.Messages.Request
  alias BeamWeaver.OpenAI.ModelPolicy
  alias BeamWeaver.OpenAI.ToolCalling
  alias BeamWeaver.Provider.ChatCompletionsWire
  alias BeamWeaver.Provider.Options

  # `config` adapts the request to another provider's Responses API:
  # `:response_id` returns the id of an assistant reply that provider stored,
  # which `use_previous_response_id: true` continues from (default: OpenAI's).
  def request_body(model, messages, opts \\ [], config \\ []) do
    {messages, previous_response_id} = previous_response_context(messages, opts, config)

    store = effective_store(model, opts)

    with :ok <- validate_request_params(model, opts),
         :ok <- validate_gpt6_options(model, opts),
         :ok <- ModelPolicy.validate_reasoning_effort(model.profile, reasoning_option(model, opts)),
         {:ok, message_input} <- Messages.to_responses_input(messages, store: store),
         {:ok, input_items} <- Messages.normalize_input_items(Keyword.get(opts, :input_items)),
         {:ok, structured_output} <- StructuredOutput.format(opts) do
      input = message_input ++ input_items
      model_name = Keyword.get(opts, :model, model.model)
      # `extra_body` goes in last, except "text", which merges into the text param.
      {extra_text, extra_body} = model |> Options.extra_body(opts) |> Map.pop("text")
      reasoning = reasoning_option(model, opts)
      text = text_option(model, opts, extra_text, structured_output)

      body =
        %{
          "model" => model_name,
          "input" => input,
          "stream" => Keyword.get(opts, :stream, false)
        }
        |> Options.put_optional(
          "access_programs",
          Options.normalize_option_map(option(model, opts, :access_programs))
        )
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
        |> Options.put_optional(
          "moderation",
          Options.normalize_option_map(option(model, opts, :moderation))
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
        |> Options.put_optional("prompt_cache_key", option(model, opts, :prompt_cache_key))
        |> Options.put_optional(
          "prompt_cache_options",
          Options.normalize_option_map(option(model, opts, :prompt_cache_options))
        )
        |> Options.put_optional(
          "prompt_cache_retention",
          Options.normalize_value(option(model, opts, :prompt_cache_retention))
        )
        |> Options.put_optional("safety_identifier", option(model, opts, :safety_identifier))
        |> Options.put_optional(
          "stream_options",
          Options.normalize_option_map(Keyword.get(opts, :stream_options))
        )
        |> Options.put_optional("top_logprobs", option(model, opts, :top_logprobs))
        |> Options.put_optional(
          "context_management",
          Options.normalize_option_list(Keyword.get(opts, :context_management))
        )
        |> Options.put_optional("logprobs", option(model, opts, :logprobs))
        |> Options.put_optional(
          "search_parameters",
          Options.normalize_value(option(model, opts, :search_parameters))
        )
        |> Options.put_optional("tool_choice", tool_choice(Keyword.get(opts, :tool_choice)))
        |> Options.put_optional("truncation", Keyword.get(opts, :truncation))
        |> Options.merge_extra_body(extra_body)

      {:ok, body}
    end
  end

  defp previous_response_context(messages, opts, config) do
    explicit_id = Keyword.get(opts, :previous_response_id)

    cond do
      not is_nil(explicit_id) ->
        {messages, explicit_id}

      Keyword.get(opts, :use_previous_response_id) == true ->
        Request.last_after_previous_response(messages, Keyword.get(config, :response_id, &Request.response_id/1))

      true ->
        {messages, nil}
    end
  end

  defp validate_request_params(model, opts) do
    model_params =
      model
      |> Map.from_struct()
      |> Map.take([
        :access_programs,
        :audio,
        :deferred,
        :extra_body,
        :frequency_penalty,
        :logprobs,
        :max_completion_tokens,
        :max_output_tokens,
        :max_tokens,
        :max_turns,
        :metadata,
        :moderation,
        :modalities,
        :parallel_tool_calls,
        :prompt,
        :prompt_cache_key,
        :prompt_cache_options,
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

    # Every model parameter of the call is checked, including ones this API
    # has no field for, so a foreign option such as `stop` is an error rather
    # than dropped.
    opts_params = Map.new(opts)

    params = Map.merge(model_params, opts_params)
    policy = Keyword.get(opts, :param_policy, model.param_policy)

    ParamPolicy.validate(model.profile, params, policy, api: :responses)
  end

  defp validate_gpt6_options(model, opts) do
    model_name = Keyword.get(opts, :model, model.model)
    reasoning = reasoning_option(model, opts)

    unsupported_sampling =
      if ModelPolicy.gpt6_sol_or_luna?(model_name) and
           not ModelPolicy.none_reasoning?(reasoning) do
        Enum.filter([:temperature, :top_p, :top_logprobs], fn param ->
          not is_nil(option(model, opts, param))
        end)
      else
        []
      end

    cond do
      not ModelPolicy.reasoning_effort_supported?(model_name, reasoning) ->
        {:error,
         Error.new(
           :invalid_model_option,
           "GPT-6 reasoning effort is not supported by this model",
           %{
             model: model_name,
             reasoning_effort: reasoning_effort(reasoning),
             supported:
               if(ModelPolicy.responses_tools_only?(model_name),
                 do: [:low, :medium, :high, :xhigh, :max],
                 else: [:none, :low, :medium, :high, :xhigh, :max]
               )
           }
         )}

      unsupported_sampling != [] ->
        {:error,
         Error.new(:invalid_model_option, "GPT-6 sampling controls require reasoning effort none", %{
           model: model_name,
           params: unsupported_sampling,
           expected_reasoning_effort: :none
         })}

      ModelPolicy.gpt6?(model_name) and not ModelPolicy.none_reasoning?(reasoning) and
          "message.output_text.logprobs" in List.wrap(Keyword.get(opts, :include)) ->
        {:error,
         Error.new(
           :invalid_model_option,
           "GPT-6 reasoning does not support message.output_text.logprobs in include",
           %{model: model_name, include: "message.output_text.logprobs"}
         )}

      true ->
        :ok
    end
  end

  defp reasoning_effort(%{"effort" => effort}), do: effort
  defp reasoning_effort(%{effort: effort}), do: effort
  defp reasoning_effort(_reasoning), do: nil

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

  defp option(model, opts, key), do: Keyword.get(opts, key, Map.get(model, key))

  # `:auto`, `:none` and `:required` (or Anthropic's `:any`) pass through; a
  # bare tool name forces that function.
  defp tool_choice(choice) do
    case ChatCompletionsWire.tool_choice(choice) do
      %{"type" => "function", "function" => %{"name" => name}} = function ->
        function |> Map.delete("function") |> Map.put("name", name)

      other ->
        other
    end
  end

  defp effective_store(model, opts) do
    case Options.extra_body(model, opts) do
      %{"store" => store} -> store
      _extra_body -> option(model, opts, :store)
    end
  end

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

  defp text_option(model, opts, extra_text, structured_output) do
    explicit_text = Keyword.get(opts, :text) |> Options.normalize_option_map()

    %{}
    |> Options.merge_optional_map(explicit_text)
    |> Options.merge_optional_map(Options.normalize_option_map(extra_text))
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
