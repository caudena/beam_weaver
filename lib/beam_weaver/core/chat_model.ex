defmodule BeamWeaver.Core.ChatModel do
  @moduledoc ~S"""
  Provider-neutral chat invocation, batching and streaming contract.

  Inputs normalize to messages. A successful invocation returns an assistant
  `BeamWeaver.Core.Message`; a provider/validation failure returns an error.
  A direct call can request tools but does not execute them. Use
  `BeamWeaver.Agent` for the full model/tool loop.

  ```elixir
  model = BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini", max_tokens: 128, timeout: 60_000)
  {:ok, reply} = BeamWeaver.Core.ChatModel.invoke(model, "Explain tracking numbers briefly.")
  true = byte_size(BeamWeaver.Core.Message.text(reply)) > 0
  ```

  Configure provider credentials as in [Installation](installation.md).
  Preserve full returned messages for continuation: display text can omit
  reasoning signatures, tool calls and native provider state.

  Typed streams return envelopes with incremental output and terminal outcomes.
  Consume streams once and inspect error events; successful construction is not
  successful inference. Batching returns per-input outcomes in input order.
  See [Models](models.md), [Messages](messages.md) and [Streaming](streaming.md).

  Adapters implement the callbacks below. The facade normalizes inputs and
  checks compatibility before dispatch; custom transports and replay can replace
  HTTP for controlled tests without establishing live-provider availability.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.LanguageModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.MapAccess
  alias BeamWeaver.Models.ProfileRegistry.Params, as: ProfileParams
  alias BeamWeaver.Stream, as: BWStream
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.Tracing
  alias BeamWeaver.Tracing.Options, as: TraceOptions
  alias BeamWeaver.Tracing.Runner, as: TraceRunner

  @generic_model_param_keys [
    :audio,
    :context_management,
    :deferred,
    :effort,
    :frequency_penalty,
    :inference_geo,
    :max_completion_tokens,
    :max_output_tokens,
    :max_tokens,
    :modalities,
    :n,
    :parallel_tool_calls,
    :reasoning,
    :reasoning_effort,
    :seed,
    :service_tier,
    :stop,
    :stop_sequences,
    :store,
    :stream,
    :stream_options,
    :stream_usage,
    :temperature,
    :thinking,
    :tool_choice,
    :top_k,
    :top_p,
    :verbosity,
    :response_format,
    :structured_output
  ]

  @excluded_invocation_param_keys [
    :api_key,
    :base_url,
    :callbacks,
    :context,
    :count_tokens_endpoint,
    :default_headers,
    :endpoint,
    :exporter,
    :exporter_opts,
    :extra_body,
    :functions,
    :input,
    :input_items,
    :instructions,
    :messages,
    :metadata,
    :mcp_servers,
    :organization,
    :project,
    :prompt,
    :runtime,
    :task_supervisor,
    :tools,
    :tokenizer,
    :trace,
    :trace?,
    :trace_metadata,
    :transport,
    :transport_opts,
    :usage
  ]

  @callback invoke(term(), [Message.t()], keyword()) ::
              {:ok, Message.t()} | {:error, Error.t() | term()}
  @callback stream(term(), [Message.t()], keyword()) ::
              {:ok, Enumerable.t()} | {:error, Error.t() | term()}
  @callback stream_events(term(), [Message.t()], keyword()) ::
              {:ok, Enumerable.t()} | {:error, Error.t() | term()}
  @callback stream_typed_events(term(), [Message.t()], keyword()) ::
              {:ok, Enumerable.t()} | {:error, Error.t() | term()}
  @callback stream_exact_typed_events(term(), binary(), keyword()) ::
              {:ok, Enumerable.t()} | {:error, Error.t() | term()}
  @callback resolve_invocation_model(term(), keyword()) ::
              {:ok, term()} | {:error, Error.t() | term()}
  @optional_callbacks stream: 3,
                      stream_events: 3,
                      stream_typed_events: 3,
                      stream_exact_typed_events: 3,
                      resolve_invocation_model: 2

  @doc """
  Resolves provider-specific per-invocation model overrides.

  Providers that attach model profiles can implement the optional callback so
  capability validation, dispatch, tracing, and response normalization all use
  the same effective model.
  """
  @spec resolve_invocation_model(term(), keyword()) ::
          {:ok, term()} | {:error, Error.t() | term()}
  def resolve_invocation_model(model, opts \\ []) do
    module = if is_map(model), do: Map.get(model, :__struct__), else: nil

    cond do
      BeamWeaver.Core.DecisionModel.model?(model) ->
        {:error,
         Error.new(:unsupported_feature, "decision models cannot generate chat; use Core.DecisionModel.invoke/3")}

      is_atom(module) and BeamWeaver.Behaviour.exported?(module, :resolve_invocation_model, 2) ->
        module.resolve_invocation_model(model, opts)

      true ->
        {:ok, model}
    end
  end

  @doc """
  Sends `messages` (a list of messages, or a string for one user message) to
  the model and returns its reply: `{:ok, message}` or `{:error, error}`.
  """
  @spec invoke(term(), term(), keyword()) ::
          {:ok, Message.t()} | {:error, Error.t() | term()}
  def invoke(model, input, opts \\ []) do
    with {:ok, model, messages} <- prepare(model, input, opts) do
      trace_call(model, messages, opts, fn ->
        case model.__struct__.invoke(model, messages, opts) do
          {:ok, %Message{} = message} ->
            BeamWeaver.Provider.Response.normalize_message_result(model, message, opts)

          {:error, _error} = error ->
            error

          other ->
            {:error,
             Error.new(:invalid_response, "chat model returned an invalid response", %{
               response: inspect(other)
             })}
        end
      end)
    end
  end

  @doc false
  @spec trace_call(term(), [Message.t()], keyword(), (-> term())) :: term()
  def trace_call(model, messages, opts, fun)
      when is_list(messages) and is_list(opts) and is_function(fun, 0) do
    if trace?(opts) do
      exporter_opts = Keyword.take(opts, [:exporter, :exporter_opts])

      TraceRunner.run(
        trace_name(model),
        [
          kind: :model,
          inputs: %{messages: messages},
          tags: model_tags(model),
          metadata: model_start_metadata(model, opts)
        ],
        exporter_opts,
        fun,
        fn run, result ->
          case result do
            {:ok, %Message{} = message} = ok ->
              usage = usage_metadata(message)

              Tracing.finish_run(
                run,
                exporter_opts ++
                  [
                    outputs: model_outputs(message, usage),
                    usage: usage,
                    metadata: model_finish_metadata(message, usage)
                  ]
              )

              ok

            {:error, error} = tagged_error ->
              Tracing.fail_run(run, error, exporter_opts)
              tagged_error

            other ->
              error =
                Error.new(:invalid_response, "chat model returned an invalid response", %{
                  response: inspect(other)
                })

              Tracing.fail_run(run, error, exporter_opts)
              other
          end
        end
      )
    else
      fun.()
    end
  end

  @doc """
  Streams a chat model response, falling back to a one-message stream when the
  provider only implements `invoke/3`.
  """
  @spec stream(term(), term(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t() | term()}
  def stream(model, input, opts \\ []) do
    with {:ok, model, messages} <- prepare(model, input, opts) do
      if BeamWeaver.Behaviour.exported?(model.__struct__, :stream, 3) do
        model.__struct__.stream(model, messages, opts)
      else
        with {:ok, message} <- invoke(model, messages, opts), do: {:ok, [message]}
      end
    end
  end

  @doc """
  Invokes a chat model for each input and returns ordered tagged results.
  """
  @spec batch(term(), [term()], keyword()) :: [{:ok, Message.t()} | {:error, Error.t() | term()}]
  def batch(model, inputs, opts \\ []) when is_list(inputs) do
    Enum.map(inputs, &invoke(model, &1, opts))
  end

  @doc """
  Streams typed chat events.

  Providers with a native `stream_events/3` keep their event shape. Other
  providers are projected through `stream/3` into `Message` and `Done`
  envelopes.
  """
  @spec stream_events(term(), term(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t() | term()}
  def stream_events(model, input, opts \\ []), do: stream_envelopes(model, input, opts, :stream_events)

  @doc """
  Streams typed BeamWeaver chat events.

  This surface is for consumers that need a stable `%BeamWeaver.Stream.Envelope{}`
  stream with typed events such as tokens, message chunks, reasoning chunks,
  tool-call chunks, and done events. Provider-specific lifecycle streams remain
  available through provider modules such as `stream_events/3` where documented.
  """
  @spec stream_typed_events(term(), term(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t() | term()}
  def stream_typed_events(model, input, opts \\ []),
    do: stream_envelopes(model, input, opts, :stream_typed_events)

  defp stream_envelopes(model, input, opts, callback) do
    with {:ok, model, messages} <- prepare(model, input, opts) do
      if BeamWeaver.Behaviour.exported?(model.__struct__, callback, 3) do
        apply(model.__struct__, callback, [model, messages, opts])
      else
        with {:ok, events} <- stream(model, messages, opts), do: {:ok, stream_event_envelopes(model, events, opts)}
      end
    end
  end

  defp prepare(model, input, opts) do
    with {:ok, messages} <- LanguageModel.normalize_chat_input(input),
         :ok <- validate_messages(messages),
         {:ok, model} <- resolve_invocation_model(model, opts),
         :ok <- BeamWeaver.Provider.Capability.validate_invocation(model, opts) do
      {:ok, model, messages}
    end
  end

  @doc """
  Streams a previously rendered canonical request body without rebuilding it.

  This boundary is intended for durable runtimes that persist and hash the exact
  request before dispatch. Decoder and transport options remain out-of-band.
  """
  @spec stream_exact_typed_events(term(), binary(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t() | term()}
  def stream_exact_typed_events(model, body, opts \\ []) when is_binary(body) do
    if BeamWeaver.Behaviour.exported?(model.__struct__, :stream_exact_typed_events, 3) do
      model.__struct__.stream_exact_typed_events(model, body, opts)
    else
      {:error, Error.new(:unsupported_feature, "chat model does not support exact request dispatch")}
    end
  end

  @doc """
  Validates chat model message input.
  """
  @spec validate_messages([term()]) :: :ok | {:error, Error.t()}
  def validate_messages(messages) when is_list(messages) do
    Enum.find_value(messages, :ok, fn message -> with :ok <- Message.validate(message), do: nil end)
  end

  defp event_envelope(%BWStream.Envelope{} = envelope, _envelope_opts), do: envelope
  defp event_envelope(event, envelope_opts), do: BWStream.envelope(event_payload(event), envelope_opts)

  # A live stream's own events: the `Error` that ends a failed stream, and
  # heartbeats.
  defp event_payload(%event{} = stream_event) when event in [Events.Error, Events.Debug], do: stream_event
  defp event_payload(%Message{} = message), do: %Events.Message{message: message}
  defp event_payload(text) when is_binary(text), do: %Events.Token{text: text}
  defp event_payload(event), do: %Events.Custom{payload: %{name: :chat_model_event, payload: event}}

  # The stream ends with `Done`, unless it failed: then its `Error` is last.
  @doc false
  def stream_event_envelopes(model, events, opts) do
    envelope_opts = [run_id: Keyword.get(opts, :run_id), node: model_name(model)]
    done = BWStream.envelope(%Events.Done{}, envelope_opts)

    Elixir.Stream.transform(
      events,
      fn -> :streaming end,
      fn
        _event, :failed ->
          {:halt, :failed}

        event, :streaming ->
          case event_envelope(event, envelope_opts) do
            %BWStream.Envelope{event: %Events.Error{}} = envelope -> {[envelope], :failed}
            envelope -> {[envelope], :streaming}
          end
      end,
      fn
        :streaming -> {[done], :streaming}
        :failed -> {[], :failed}
      end,
      fn _state -> :ok end
    )
  end

  defp model_name(%{__struct__: module}), do: module |> Module.split() |> List.last()

  @doc false
  def trace?(opts) do
    Keyword.get(opts, :trace?, Keyword.get(opts, :trace, true)) != false and
      (not is_nil(Tracing.capture_context()) or Keyword.has_key?(opts, :exporter) or
         Tracing.exporter_configured?())
  end

  defp trace_name(model) do
    case Enum.reject([model_provider(model), model_identifier(model)], &is_nil/1) do
      [] -> model_name(model)
      parts -> Enum.join(parts, ":")
    end
  end

  defp model_tags(model) do
    [:model, model_provider(model)]
    |> Enum.reject(&is_nil/1)
  end

  defp model_start_metadata(model, opts) do
    provider = model_provider(model)
    identifier = model_identifier(model)
    profile = model |> traced_model() |> MapAccess.get(:profile)

    %{}
    |> maybe_put(:model_provider, provider)
    |> maybe_put(:provider, provider)
    |> maybe_put(:model_name, identifier)
    |> maybe_put(:model, identifier)
    |> maybe_put(:model_reasoning_output, MapAccess.get(profile, :reasoning_output))
    |> maybe_put(:invocation_params, invocation_params(model, opts))
    |> maybe_put(:tools, tool_names(Keyword.get(opts, :tools)))
    |> maybe_put(:tool_definitions, tool_definitions(Keyword.get(opts, :tools)))
    |> maybe_put(:structured_output, structured_output_mode(opts))
    |> maybe_put(:structured_output_strategy, Keyword.get(opts, :structured_output_strategy))
    |> maybe_put(:structured_output_requested_strategy, Keyword.get(opts, :structured_output_requested_strategy))
    |> maybe_put(:structured_output_effective_strategy, Keyword.get(opts, :structured_output_effective_strategy))
    |> maybe_put(:structured_output_fallback_reason, Keyword.get(opts, :structured_output_fallback_reason))
    |> maybe_put(:structured_output_schema_bytes, Keyword.get(opts, :structured_output_schema_bytes))
    |> maybe_put(:structured_output_schema_properties, Keyword.get(opts, :structured_output_schema_properties))
    |> maybe_put(:structured_output_tool_names, Keyword.get(opts, :structured_output_tool_names))
    |> Map.merge(Map.new(Keyword.get(opts, :trace_metadata) || %{}))
    |> TraceOptions.metadata(Keyword.get(opts, :trace))
  end

  # The run keeps its start metadata, so the finish adds only what the reply
  # tells.
  defp model_finish_metadata(%Message{} = message, usage) do
    response_metadata = message.response_metadata || %{}

    %{}
    |> maybe_put(:response_metadata, response_metadata)
    |> maybe_put(
      :finish_reason,
      metadata_first(response_metadata, [:finish_reason, :stop_reason])
    )
    |> maybe_put(:request_id, response_request_id(response_metadata))
    |> maybe_put(:usage_metadata, usage)
  end

  defp response_request_id(response_metadata) do
    metadata_first(response_metadata, [:request_id]) ||
      response_metadata
      |> metadata_first([:transport])
      |> metadata_first([:request_id]) ||
      metadata_first(response_metadata, [:id])
  end

  defp model_outputs(%Message{} = message, usage) do
    %{messages: [message]}
    |> maybe_put(:usage_metadata, usage)
  end

  defp invocation_params(model, opts) do
    identifier = model_identifier(model)
    param_keys = invocation_param_keys(model)

    model_params =
      model
      |> model_param_map()
      |> approved_param_map(param_keys)
      |> maybe_merge_extra_body(model, param_keys)

    call_params =
      opts
      |> approved_param_map(param_keys)
      |> reject_nil_or_empty()

    model_params
    |> Map.merge(call_params)
    |> maybe_put(:model, identifier)
    |> maybe_put(:model_name, identifier)
    |> maybe_put(:response_format, Keyword.get(opts, :response_format) || Keyword.get(opts, :structured_output))
    |> reject_nil_or_empty()
  end

  defp invocation_param_keys(model) do
    model
    |> provider_params()
    |> Kernel.++(@generic_model_param_keys)
    |> Enum.uniq()
    |> Enum.reject(&(&1 in @excluded_invocation_param_keys))
  end

  defp provider_params(%{__struct__: module}) do
    case Module.split(module) do
      ["BeamWeaver", "OpenAI", "ChatModel"] -> ProfileParams.responses()
      ["BeamWeaver", "OpenAI", "ChatCompletionsModel"] -> ProfileParams.chat_completions()
      ["BeamWeaver", "Anthropic", "ChatModel"] -> ProfileParams.anthropic()
      ["BeamWeaver", "Google", "ChatModel"] -> ProfileParams.google()
      ["BeamWeaver", "XAI", "ChatModel"] -> ProfileParams.xai_responses()
      ["BeamWeaver", "XAI", "ChatCompletionsModel"] -> ProfileParams.xai_chat_completions()
      ["BeamWeaver", "Moonshot", "ChatModel"] -> ProfileParams.moonshot()
      ["BeamWeaver", "ZAI", "ChatModel"] -> ProfileParams.zai()
      ["BeamWeaver", "DeepSeek", "ChatModel"] -> ProfileParams.deepseek_chat_completions()
      ["BeamWeaver", "DeepSeek", "ResponsesModel"] -> ProfileParams.deepseek_responses()
      ["BeamWeaver", "Models", "FakeChatModel"] -> all_provider_params()
      _other -> []
    end
  end

  defp provider_params(_model), do: []

  defp all_provider_params do
    List.flatten([
      ProfileParams.responses(),
      ProfileParams.chat_completions(),
      ProfileParams.anthropic(),
      ProfileParams.google(),
      ProfileParams.xai_responses(),
      ProfileParams.xai_chat_completions(),
      ProfileParams.moonshot(),
      ProfileParams.zai(),
      ProfileParams.deepseek_chat_completions(),
      ProfileParams.deepseek_responses()
    ])
  end

  defp approved_param_map(values, param_keys) do
    for {key, value} <- values, key = approved_param_key(key, param_keys), into: %{}, do: {key, value}
  end

  defp approved_param_key(key, param_keys) when is_atom(key) do
    if key in param_keys, do: key
  end

  defp approved_param_key(key, param_keys) when is_binary(key),
    do: Enum.find(param_keys, &(Atom.to_string(&1) == key))

  defp approved_param_key(_key, _param_keys), do: nil

  defp model_param_map(%{__struct__: _module} = model) do
    model
    |> traced_model()
    |> Map.from_struct()
    |> Map.drop([:api_key, :default_headers, :endpoint, :organization, :project])
  end

  defp model_param_map(model) when is_map(model), do: model
  defp model_param_map(_model), do: %{}

  defp maybe_merge_extra_body(params, model, param_keys) do
    case MapAccess.get(model, :extra_body) do
      extra_body when is_map(extra_body) and map_size(extra_body) > 0 ->
        Map.merge(params, approved_param_map(extra_body, param_keys))

      _other ->
        params
    end
  end

  defp model_provider(model) do
    model = traced_model(model)

    (MapAccess.get(model, :model_provider) || MapAccess.get(model, :provider) || module_provider(model))
    |> normalize_string()
  end

  # Wrappers such as `Models.cached/3` keep the model they wrap in `:model`;
  # traces describe the wrapped model.
  defp traced_model(model) do
    case MapAccess.get(model, :model) do
      %{__struct__: _module} = inner -> traced_model(inner)
      _other -> model
    end
  end

  defp module_provider(%{__struct__: module}) do
    parts = Module.split(module)

    cond do
      "OpenAI" in parts -> "openai"
      "Anthropic" in parts -> "anthropic"
      "Google" in parts -> "google"
      "XAI" in parts -> "xai"
      "Moonshot" in parts -> "moonshot"
      "ZAI" in parts -> "zai"
      "DeepSeek" in parts -> "deepseek"
      parts == ["BeamWeaver", "Models", "FakeChatModel"] -> "fake"
      true -> nil
    end
  end

  defp module_provider(_model), do: nil

  defp model_identifier(model) do
    model = traced_model(model)

    (module_value(model, :model_name) || module_value(model, :model_id) || MapAccess.get(model, :model) ||
       MapAccess.get(model, :id))
    |> normalize_string()
  end

  defp module_value(%{__struct__: module} = model, function) do
    if BeamWeaver.Behaviour.exported?(module, function, 1), do: apply(module, function, [model])
  end

  defp module_value(_model, _function), do: nil

  defp structured_output_mode(opts) do
    cond do
      Keyword.has_key?(opts, :response_format) -> :response_format
      Keyword.has_key?(opts, :structured_output) -> :structured_output
      true -> nil
    end
  end

  defp tool_definitions(tools) do
    tools
    |> List.wrap()
    |> Enum.flat_map(&tool_definition_entries/1)
    |> Enum.reject(&nil_or_empty?/1)
  end

  defp tool_definition_entries(tool) do
    case trace_tools(tool) do
      tools when is_list(tools) and tools != [] -> tools
      _other -> [tool_definition(tool)]
    end
  end

  defp trace_tools(tool) do
    case safe_tool_metadata(tool) do
      %{trace_tools: tools} -> tools
      %{"trace_tools" => tools} -> tools
      _metadata -> nil
    end
  end

  defp tool_definition(%{} = tool) when not is_struct(tool), do: tool

  defp tool_definition(tool) do
    %{
      name: Tool.name(tool),
      description: Tool.description(tool),
      input_schema: Tool.input_schema(tool)
    }
  rescue
    _exception -> nil
  end

  defp safe_tool_metadata(tool) do
    Tool.metadata(tool)
  rescue
    _exception -> %{}
  end

  defp tool_names(tools) do
    tools
    |> List.wrap()
    |> Enum.map(&tool_name/1)
    |> Enum.reject(&is_nil/1)
  end

  defp tool_name(%{name: name}), do: normalize_string(name)
  defp tool_name(%{"name" => name}), do: normalize_string(name)

  defp tool_name(tool) do
    Tool.name(tool)
  rescue
    _exception -> fallback_tool_name(tool)
  end

  defp fallback_tool_name(fun) when is_function(fun) do
    case Function.info(fun, :name) do
      {:name, name} when is_atom(name) -> Atom.to_string(name)
      _other -> nil
    end
  end

  defp fallback_tool_name(%{__struct__: module}), do: module |> Module.split() |> List.last()
  defp fallback_tool_name(_tool), do: nil

  defp usage_metadata(%Message{usage_metadata: usage, response_metadata: metadata}) do
    usage = normalize_usage_metadata(usage)

    metadata_usage =
      metadata
      |> metadata_first([:usage_metadata, :usage, :token_usage])
      |> normalize_usage_metadata()

    usage = if map_size(usage) > 0, do: usage, else: metadata_usage

    usage
    |> maybe_put(
      :service_tier,
      usage[:service_tier] || metadata_usage[:service_tier] || metadata_first(metadata, [:service_tier])
    )
    |> maybe_put(
      :inference_geo,
      usage[:inference_geo] || metadata_usage[:inference_geo] || metadata_first(metadata, [:inference_geo])
    )
  end

  defp normalize_usage_metadata(usage) when is_map(usage) do
    input_details = metadata_first(usage, [:input_token_details, :input_tokens_details]) || %{}
    output_details = metadata_first(usage, [:output_token_details, :output_tokens_details]) || %{}

    %{
      input_tokens: metadata_first(usage, [:input_tokens, :prompt_tokens]),
      output_tokens: metadata_first(usage, [:output_tokens, :completion_tokens]),
      total_tokens: metadata_first(usage, [:total_tokens]),
      cache_read_tokens:
        metadata_first(usage, [:cache_read_tokens, :cache_read_input_tokens]) ||
          metadata_first(input_details, [:cache_read, :cache_read_tokens, :cache_read_input_tokens]),
      cache_creation_tokens:
        metadata_first(usage, [:cache_creation_tokens, :cache_creation_input_tokens]) ||
          metadata_first(input_details, [
            :cache_creation,
            :cache_creation_tokens,
            :cache_creation_input_tokens,
            :cache_write,
            :cache_write_tokens
          ]),
      reasoning_tokens:
        metadata_first(usage, [:reasoning_tokens]) ||
          metadata_first(output_details, [:reasoning, :reasoning_tokens]),
      thinking_tokens:
        metadata_first(usage, [:thinking_tokens]) ||
          metadata_first(output_details, [:thinking, :thinking_tokens]),
      service_tier: metadata_first(usage, [:service_tier, :pricing_tier, :speed]),
      inference_geo: metadata_first(usage, [:inference_geo]),
      input_cost: metadata_first(usage, [:input_cost]),
      output_cost: metadata_first(usage, [:output_cost]),
      total_cost: metadata_first(usage, [:total_cost]),
      input_token_details: input_details,
      output_token_details: output_details,
      input_cost_details: metadata_first(usage, [:input_cost_details]),
      output_cost_details: metadata_first(usage, [:output_cost_details])
    }
    |> reject_nil_or_empty()
  end

  defp normalize_usage_metadata(_usage), do: %{}

  defp metadata_first(metadata, keys) when is_map(metadata) do
    Enum.find_value(keys, &Map.get(metadata, &1))
  end

  # `nil`, or a value such as a string where a provider's metadata map would
  # be, has none of the keys.
  defp metadata_first(_metadata, _keys), do: nil

  defp normalize_string(nil), do: nil
  defp normalize_string(value), do: to_string(value)

  defp maybe_put(map, key, value), do: if(nil_or_empty?(value), do: map, else: Map.put(map, key, value))

  defp reject_nil_or_empty(map) do
    Map.reject(map, fn {_key, value} -> nil_or_empty?(value) end)
  end

  defp nil_or_empty?(nil), do: true
  defp nil_or_empty?(%{} = map), do: map_size(map) == 0
  defp nil_or_empty?([]), do: true
  defp nil_or_empty?(_value), do: false
end
