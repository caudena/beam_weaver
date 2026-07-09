defmodule BeamWeaver.OpenAI.ChatCompletions.Options.Body do
  @moduledoc false

  alias BeamWeaver.OpenAI.ChatCompletions.Messages
  alias BeamWeaver.OpenAI.ChatCompletions.Options.Validation
  alias BeamWeaver.OpenAI.Error
  alias BeamWeaver.OpenAI.MessageParts
  alias BeamWeaver.OpenAI.ModelPolicy
  alias BeamWeaver.Provider.Options

  @spec to_body(BeamWeaver.OpenAI.ChatCompletions.Options.t(), term(), [
          BeamWeaver.Core.Message.t()
        ]) ::
          {:ok, map()} | {:error, Error.t()}
  def to_body(%BeamWeaver.OpenAI.ChatCompletions.Options{opts: opts}, model, messages) do
    with :ok <- Validation.validate(model, opts),
         {:ok, openai_messages} <- Messages.to_openai_messages(messages),
         {:ok, response_format} <- response_format(opts) do
      model_name = Keyword.get(opts, :model, Map.get(model, :model))
      model_kwargs = option(model, opts, :model_kwargs) || %{}
      openai_messages = coerce_openai_messages(model_name, openai_messages)
      reasoning_effort = Options.normalize_value(option(model, opts, :reasoning_effort))

      body =
        %{
          "model" => model_name,
          "messages" => openai_messages
        }
        |> merge_model_kwargs(model_kwargs)
        |> Options.put_optional("tools", tools(opts))
        |> Options.put_optional(
          "tool_choice",
          Options.normalize_value(Keyword.get(opts, :tool_choice))
        )
        |> Options.put_optional("response_format", response_format)
        |> Options.put_optional("reasoning_effort", reasoning_effort)
        |> Options.put_optional(
          "temperature",
          ModelPolicy.request_temperature(
            model_name,
            option(model, opts, :temperature),
            %{"effort" => reasoning_effort}
          )
        )
        |> Options.put_optional("max_tokens", max_tokens_option(model_name, model, opts))
        |> Options.put_optional(
          "max_completion_tokens",
          max_completion_tokens_option(model_name, model, opts)
        )
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
        |> Options.put_optional("stream", Keyword.get(opts, :stream, false))
        |> Options.put_optional(
          "stream_options",
          Options.normalize_option_map(Keyword.get(opts, :stream_options))
        )
        |> Options.put_optional(
          "prediction",
          Options.normalize_value(Keyword.get(opts, :prediction))
        )
        |> Options.put_optional("logprobs", Keyword.get(opts, :logprobs))
        |> Options.put_optional(
          "logit_bias",
          Options.normalize_option_map(option(model, opts, :logit_bias))
        )
        |> Options.put_optional("top_logprobs", Keyword.get(opts, :top_logprobs))
        |> Options.put_optional("n", Keyword.get(opts, :n))
        |> Options.put_optional("stop", Keyword.get(opts, :stop))
        |> Options.put_optional(
          "function_call",
          Options.normalize_value(option(model, opts, :function_call))
        )
        |> Options.put_optional(
          "functions",
          Options.normalize_value(option(model, opts, :functions))
        )
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
          "verbosity",
          Options.normalize_value(option(model, opts, :verbosity))
        )
        |> Options.put_optional(
          "web_search_options",
          Options.normalize_value(option(model, opts, :web_search_options))
        )
        |> Options.put_optional(
          "search_parameters",
          Options.normalize_value(option(model, opts, :search_parameters))
        )
        |> Options.merge_extra_body(Keyword.get(opts, :extra_body, %{}))

      {:ok, body}
    end
  end

  defp tools(opts) do
    case Keyword.get(opts, :tools, []) do
      [] -> nil
      tools when is_list(tools) -> Messages.tools_to_openai(tools)
    end
  end

  defp response_format(opts) do
    case Keyword.get(opts, :response_format) || Keyword.get(opts, :structured_output) do
      nil ->
        {:ok, nil}

      %{"type" => _type} = format ->
        {:ok, format}

      %{type: type} = format when is_binary(type) ->
        {:ok, MessageParts.stringify_keys(format)}

      %{name: name, schema: schema} = format when is_binary(name) and is_map(schema) ->
        {:ok, Messages.structured_output_format(name, schema, strict: Map.get(format, :strict, true))}

      %{"name" => name, "schema" => schema} = format when is_binary(name) and is_map(schema) ->
        {:ok, Messages.structured_output_format(name, schema, strict: Map.get(format, "strict", true))}

      {name, schema} when is_binary(name) and is_map(schema) ->
        {:ok, Messages.structured_output_format(name, schema)}

      other ->
        {:error,
         Error.new(:invalid_response_format, "structured output requires a name and schema", %{
           response_format: inspect(other)
         })}
    end
  end

  defp option(model, opts, key), do: Keyword.get(opts, key, Map.get(model, key))

  defp max_tokens_option(model_name, model, opts) do
    max_tokens = option(model, opts, :max_tokens)

    if ModelPolicy.completion_tokens_field_model?(model_name) do
      nil
    else
      max_tokens
    end
  end

  defp max_completion_tokens_option(model_name, model, opts) do
    option(model, opts, :max_completion_tokens) ||
      option(model, opts, :max_output_tokens) ||
      completion_tokens_alias(model_name, option(model, opts, :max_tokens))
  end

  defp completion_tokens_alias(model_name, max_tokens) do
    if ModelPolicy.completion_tokens_field_model?(model_name), do: max_tokens, else: nil
  end

  defp merge_model_kwargs(body, model_kwargs) when map_size(model_kwargs) == 0, do: body

  defp merge_model_kwargs(body, model_kwargs) when is_map(model_kwargs),
    do: Map.merge(body, Options.stringify_keys(model_kwargs))

  defp coerce_openai_messages(model_name, messages) when is_binary(model_name) do
    if o_series_model?(model_name) do
      Enum.map(messages, fn
        %{"role" => "system"} = message -> %{message | "role" => "developer"}
        message -> message
      end)
    else
      messages
    end
  end

  defp coerce_openai_messages(_model_name, messages), do: messages

  defp o_series_model?(model_name) do
    model_name
    |> String.downcase()
    |> String.starts_with?("o")
  end
end
