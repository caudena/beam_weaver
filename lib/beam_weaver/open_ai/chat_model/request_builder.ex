defmodule BeamWeaver.OpenAI.ChatModel.RequestBuilder do
  @moduledoc false

  import BeamWeaver.Provider.Options, only: [option: 3]

  alias BeamWeaver.Models.ParamPolicy
  alias BeamWeaver.OpenAI.ChatModel.StructuredOutput
  alias BeamWeaver.Core.Error
  alias BeamWeaver.OpenAI.MessageParts
  alias BeamWeaver.OpenAI.Messages
  alias BeamWeaver.OpenAI.Messages.Request
  alias BeamWeaver.OpenAI.ModelPolicy
  alias BeamWeaver.OpenAI.ToolCalling
  alias BeamWeaver.Provider.ChatCompletionsWire
  alias BeamWeaver.Provider.Options

  # Request fields from the call's option, or else the model's: sent as they
  # are, as maps with string keys, or normalized. Then those only a call sets.
  @model_fields ~w(top_p frequency_penalty presence_penalty seed parallel_tool_calls user modalities store max_turns
                   prompt_cache_key safety_identifier top_logprobs logprobs)a
  @model_map_fields ~w(access_programs metadata moderation audio prompt_cache_options)a
  @model_value_fields ~w(service_tier prompt_cache_retention)a
  @call_fields ~w(background include instructions max_tool_calls truncation)a
  @call_map_fields ~w(stream_options)a
  @call_value_fields ~w(conversation prompt)a

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
        |> MessageParts.put_fields(@model_fields, &option(model, opts, &1))
        |> MessageParts.put_fields(@model_map_fields, &Options.normalize_option_map(option(model, opts, &1)))
        |> MessageParts.put_fields(@model_value_fields, &Options.normalize_value(option(model, opts, &1)))
        |> MessageParts.put_fields(@call_fields, &Keyword.get(opts, &1))
        |> MessageParts.put_fields(@call_map_fields, &Options.normalize_option_map(Keyword.get(opts, &1)))
        |> MessageParts.put_fields(@call_value_fields, &Options.normalize_value(Keyword.get(opts, &1)))
        |> Options.put_optional("tools", tools(opts))
        |> Options.put_optional("text", text)
        |> Options.put_optional("reasoning", reasoning)
        |> Options.put_optional(
          "temperature",
          ModelPolicy.request_temperature(model_name, option(model, opts, :temperature), reasoning)
        )
        |> Options.put_optional("max_output_tokens", max_output_tokens_option(model, opts))
        |> Options.put_optional("previous_response_id", previous_response_id)
        |> Options.put_optional(
          "context_management",
          Options.normalize_option_list(Keyword.get(opts, :context_management))
        )
        |> Options.put_optional("tool_choice", tool_choice(Keyword.get(opts, :tool_choice)))
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
    params = Map.merge(model_params, Map.new(opts))

    ParamPolicy.validate(model.profile, params, option(model, opts, :param_policy), api: :responses)
  end

  defp validate_gpt6_options(model, opts) do
    model_name = Keyword.get(opts, :model, model.model)
    reasoning = reasoning_option(model, opts)
    sampling = Enum.reject([:temperature, :top_p, :top_logprobs], &is_nil(option(model, opts, &1)))

    with :ok <- ModelPolicy.validate_gpt6_effort(model_name, reasoning, reasoning_effort(reasoning)),
         :ok <- ModelPolicy.validate_gpt6_sampling(model_name, reasoning, sampling) do
      if ModelPolicy.gpt6?(model_name) and not ModelPolicy.none_reasoning?(reasoning) and
           "message.output_text.logprobs" in List.wrap(Keyword.get(opts, :include)) do
        {:error,
         Error.new(
           :invalid_model_option,
           "GPT-6 reasoning does not support message.output_text.logprobs in include",
           %{model: model_name, include: "message.output_text.logprobs"}
         )}
      else
        :ok
      end
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

  # A nil field of `:reasoning`, such as `effort: nil`, is unset, so it is left
  # out; one with no fields left is as if no `:reasoning` were given.
  defp reasoning_option(model, opts) do
    case model |> option(opts, :reasoning) |> drop_nil_fields() do
      nil ->
        case option(model, opts, :reasoning_effort) do
          nil -> nil
          effort -> %{"effort" => Options.normalize_value(effort)}
        end

      reasoning ->
        Options.normalize_option_map(reasoning)
    end
  end

  defp drop_nil_fields(reasoning) when is_map(reasoning),
    do: reasoning |> Options.reject_nil_values() |> Options.empty_to_nil()

  defp drop_nil_fields(reasoning), do: reasoning

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
end
