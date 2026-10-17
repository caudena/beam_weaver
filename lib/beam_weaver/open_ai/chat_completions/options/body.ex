defmodule BeamWeaver.OpenAI.ChatCompletions.Options.Body do
  @moduledoc false

  import BeamWeaver.Provider.Options, only: [option: 3]

  alias BeamWeaver.OpenAI.ChatCompletions.Messages
  alias BeamWeaver.OpenAI.ChatCompletions.Options.Validation
  alias BeamWeaver.Core.Error
  alias BeamWeaver.OpenAI.MessageParts
  alias BeamWeaver.OpenAI.ModelPolicy
  alias BeamWeaver.Provider.ChatCompletionsWire
  alias BeamWeaver.Provider.Options

  @spec to_body(term(), [BeamWeaver.Core.Message.t()], keyword()) :: {:ok, map()} | {:error, Error.t()}
  def to_body(model, messages, opts) do
    with :ok <- Validation.validate(model, opts),
         {:ok, openai_messages} <- Messages.to_openai_messages(messages),
         {:ok, tools} <- tools(opts),
         {:ok, response_format} <- response_format(opts) do
      model_name = Keyword.get(opts, :model, Map.get(model, :model))
      openai_messages = coerce_openai_messages(model_name, openai_messages)
      reasoning_effort = Options.normalize_value(option(model, opts, :reasoning_effort))

      body =
        %{
          "model" => model_name,
          "messages" => openai_messages
        }
        |> Options.put_optional("tools", tools)
        |> Options.put_optional("tool_choice", ChatCompletionsWire.tool_choice(Keyword.get(opts, :tool_choice)))
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
        |> put_output_cap(model_name, model, opts)
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
        |> Options.merge_extra_body(Options.extra_body(model, opts))

      {:ok, body}
    end
  end

  defp tools(opts) do
    case Keyword.get(opts, :tools, []) do
      [] -> {:ok, nil}
      tools when is_list(tools) -> Messages.Request.render_tools(tools)
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

  # A request carries one output cap: the call's, else the model's. GPT-5,
  # GPT-6 and o-series models take it as `max_completion_tokens`; other
  # models under the name it was given, with `max_output_tokens`, the
  # Responses API's name, sent as `max_completion_tokens`.
  @output_caps [
    max_completion_tokens: "max_completion_tokens",
    max_output_tokens: "max_completion_tokens",
    max_tokens: "max_tokens"
  ]

  defp put_output_cap(body, model_name, model, opts) do
    case output_cap(&Keyword.get(opts, &1)) || output_cap(&Map.get(model, &1)) do
      nil ->
        body

      {field, value} ->
        field = if ModelPolicy.completion_tokens_field_model?(model_name), do: "max_completion_tokens", else: field
        Map.put(body, field, value)
    end
  end

  defp output_cap(get) do
    Enum.find_value(@output_caps, fn {key, field} ->
      if value = get.(key), do: {field, value}
    end)
  end

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
