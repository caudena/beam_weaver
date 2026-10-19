defmodule BeamWeaver.OpenAI.ChatCompletions.Options.Body do
  @moduledoc false

  import BeamWeaver.Provider.Options, only: [option: 3]

  alias BeamWeaver.OpenAI.ChatCompletions.Messages
  alias BeamWeaver.OpenAI.ChatCompletions.Options.Validation
  alias BeamWeaver.OpenAI.ChatModel.StructuredOutput
  alias BeamWeaver.Core.Error
  alias BeamWeaver.OpenAI.MessageParts
  alias BeamWeaver.OpenAI.ModelPolicy
  alias BeamWeaver.Provider.ChatCompletionsWire
  alias BeamWeaver.Provider.Options

  # Request fields from the call's option, or else the model's: sent as they
  # are, as maps with string keys, or normalized. Then those only a call sets.
  @model_fields ~w(top_p frequency_penalty presence_penalty seed parallel_tool_calls user modalities store
                   prompt_cache_key safety_identifier)a
  @model_map_fields ~w(metadata moderation audio logit_bias prompt_cache_options)a
  @model_value_fields ~w(service_tier function_call functions prompt_cache_retention verbosity web_search_options guidelines)a
  @call_fields ~w(logprobs top_logprobs n stop)a
  @call_map_fields ~w(stream_options)a
  @call_value_fields ~w(prediction)a

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
        |> MessageParts.put_fields(@model_fields, &option(model, opts, &1))
        |> MessageParts.put_fields(@model_map_fields, &Options.normalize_option_map(option(model, opts, &1)))
        |> MessageParts.put_fields(@model_value_fields, &Options.normalize_value(option(model, opts, &1)))
        |> MessageParts.put_fields(@call_fields, &Keyword.get(opts, &1))
        |> MessageParts.put_fields(@call_map_fields, &Options.normalize_option_map(Keyword.get(opts, &1)))
        |> MessageParts.put_fields(@call_value_fields, &Options.normalize_value(Keyword.get(opts, &1)))
        |> Options.put_optional("stream", Keyword.get(opts, :stream, false))
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

      format ->
        StructuredOutput.schema_format(format, &Messages.structured_output_format/3)
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
