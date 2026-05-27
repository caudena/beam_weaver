defmodule BeamWeaver.Core.ChatModel do
  @moduledoc """
  Behaviour for chat model providers.
  """

  alias BeamWeaver.Config
  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.LanguageModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.MapAccess
  alias BeamWeaver.Result
  alias BeamWeaver.Stream, as: BWStream
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.Tracing
  alias BeamWeaver.Tracing.Runner, as: TraceRunner

  @safe_model_param_keys [
    :audio,
    :context_management,
    :deferred,
    :effort,
    :frequency_penalty,
    :inference_geo,
    :max_completion_tokens,
    :max_output_tokens,
    :max_tokens,
    :mcp_servers,
    :modalities,
    :n,
    :parallel_tool_calls,
    :reasoning,
    :reasoning_effort,
    :reuse_last_container,
    :search_parameters,
    :seed,
    :service_tier,
    :stop_sequences,
    :store,
    :stream,
    :temperature,
    :thinking,
    :timeout,
    :top_k,
    :top_p,
    :verbosity
  ]

  @internal_call_opt_keys [
    :cache,
    :callbacks,
    :context,
    :exporter,
    :exporter_opts,
    :messages,
    :runtime,
    :task_supervisor,
    :tools,
    :transport,
    :transport_opts
  ]

  @usage_metadata_keys [
    :input_tokens,
    :output_tokens,
    :total_tokens,
    :input_cost,
    :output_cost,
    :total_cost,
    :input_token_details,
    :output_token_details,
    :input_cost_details,
    :output_cost_details
  ]

  @callback invoke(term(), [Message.t()], keyword()) ::
              {:ok, Message.t()} | {:error, Error.t() | term()}
  @callback stream(term(), [Message.t()], keyword()) ::
              {:ok, Enumerable.t()} | {:error, Error.t() | term()}
  @callback stream_events(term(), [Message.t()], keyword()) ::
              {:ok, Enumerable.t()} | {:error, Error.t() | term()}
  @optional_callbacks stream: 3, stream_events: 3

  @doc """
  Invokes a chat model after validating message input.
  """
  @spec invoke(term(), term(), keyword()) ::
          {:ok, Message.t()} | {:error, Error.t() | term()}
  def invoke(model, messages, opts \\ [])

  def invoke(model, input, opts) do
    with {:ok, messages} <- LanguageModel.normalize_chat_input(input),
         :ok <- validate_messages(messages),
         :ok <- BeamWeaver.Provider.Capability.validate_invocation(model, opts) do
      trace_call(model, messages, opts, fn ->
        with {:ok, %Message{} = message} <- model.__struct__.invoke(model, messages, opts),
             message <- BeamWeaver.Provider.Response.normalize_message(model, message, opts),
             :ok <- Message.validate(message) do
          {:ok, message}
        else
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
    if trace_model_call?(opts) do
      exporter_opts = tracing_exporter_opts(opts)

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
                    metadata: model_finish_metadata(model, opts, message, usage)
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
    with {:ok, messages} <- LanguageModel.normalize_chat_input(input),
         :ok <- validate_messages(messages),
         :ok <- BeamWeaver.Provider.Capability.validate_invocation(model, opts) do
      if function_exported_loaded?(model.__struct__, :stream, 3) do
        model.__struct__.stream(model, messages, opts)
      else
        case invoke(model, messages, opts) do
          {:ok, %Message{} = message} -> {:ok, [message]}
          {:error, _error} = error -> error
        end
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
  Generates one chat response for each input, returning either all messages or
  the first tagged error.
  """
  @spec generate(term(), [term()], keyword()) :: {:ok, [Message.t()]} | {:error, term()}
  def generate(model, inputs, opts \\ []) when is_list(inputs) do
    inputs
    |> then(&batch(model, &1, opts))
    |> Result.collect()
  end

  @doc """
  Generates chat responses from prompt values or prompt-like inputs.
  """
  @spec generate_prompt(term(), [term()], keyword()) :: {:ok, [Message.t()]} | {:error, term()}
  def generate_prompt(model, prompts, opts \\ []) when is_list(prompts) do
    generate(model, prompts, opts)
  end

  @doc """
  Starts an async chat model invocation.
  """
  @spec async_invoke(term(), [Message.t()], keyword()) :: Async.handle()
  def async_invoke(model, messages, opts \\ []) do
    Async.run_call(opts, &invoke(model, messages, &1))
  end

  @doc """
  Starts async chat model streaming.
  """
  @spec async_stream(term(), [Message.t()], keyword()) :: Async.handle()
  def async_stream(model, messages, opts \\ []) do
    Async.run_call(opts, &stream(model, messages, &1))
  end

  @doc """
  Starts an ordered async batch of chat invocations.
  """
  @spec async_batch(term(), [[Message.t()]], keyword()) :: [Async.handle()]
  def async_batch(model, message_batches, opts \\ []) when is_list(message_batches) do
    Async.batch_call(message_batches, opts, &invoke(model, &1, &2))
  end

  @spec async_generate(term(), [term()], keyword()) :: Async.handle()
  def async_generate(model, inputs, opts \\ []) do
    Async.run_call(opts, &generate(model, inputs, &1))
  end

  @spec async_generate_prompt(term(), [term()], keyword()) :: Async.handle()
  def async_generate_prompt(model, prompts, opts \\ []) do
    Async.run_call(opts, &generate_prompt(model, prompts, &1))
  end

  @doc """
  Streams typed chat events.

  Providers with a native `stream_events/3` keep their event shape. Other
  providers are projected through `stream/3` into `Message` and `Done`
  envelopes.
  """
  @spec stream_events(term(), term(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t() | term()}
  def stream_events(model, input, opts \\ []) do
    with {:ok, messages} <- LanguageModel.normalize_chat_input(input),
         :ok <- validate_messages(messages),
         :ok <- BeamWeaver.Provider.Capability.validate_invocation(model, opts) do
      if function_exported_loaded?(model.__struct__, :stream_events, 3) do
        model.__struct__.stream_events(model, messages, opts)
      else
        case stream(model, messages, opts) do
          {:ok, events} -> {:ok, stream_event_envelopes(model, events, opts)}
          {:error, _error} = error -> error
        end
      end
    end
  end

  @spec async_stream_events(term(), term(), keyword()) :: Async.handle()
  def async_stream_events(model, input, opts \\ []) do
    Async.run_call(opts, &stream_events(model, input, &1))
  end

  @doc """
  Validates chat model message input.
  """
  @spec validate_messages([term()]) :: :ok | {:error, Error.t()}
  def validate_messages(messages) when is_list(messages) do
    case Enum.find_value(messages, &message_error/1) do
      nil -> :ok
      error -> {:error, error}
    end
  end

  defp message_error(message) do
    case Message.validate(message) do
      :ok -> nil
      {:error, error} -> error
    end
  end

  defp event_envelope(_model, %BWStream.Envelope{} = envelope, _opts), do: envelope

  defp event_envelope(model, %Message{} = message, opts) do
    BWStream.envelope(
      %Events.Message{message: message},
      run_id: Keyword.get(opts, :run_id),
      node: model_name(model)
    )
  end

  defp event_envelope(model, text, opts) when is_binary(text) do
    BWStream.envelope(
      %Events.Token{text: text},
      run_id: Keyword.get(opts, :run_id),
      node: model_name(model)
    )
  end

  defp event_envelope(model, event, opts) do
    BWStream.envelope(
      %Events.Custom{payload: %{name: :chat_model_event, payload: event}},
      run_id: Keyword.get(opts, :run_id),
      node: model_name(model)
    )
  end

  defp stream_event_envelopes(model, events, opts) do
    done =
      BWStream.envelope(
        %Events.Done{},
        run_id: Keyword.get(opts, :run_id),
        node: model_name(model)
      )

    events
    |> Elixir.Stream.map(&event_envelope(model, &1, opts))
    |> Elixir.Stream.concat([done])
  end

  defp model_name(%{__struct__: module}), do: module |> Module.split() |> List.last()

  defp function_exported_loaded?(module, function, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end

  defp trace_model_call?(opts) do
    trace? = Keyword.get(opts, :trace?, Keyword.get(opts, :trace, true))

    trace? != false and
      (not is_nil(Tracing.capture_context()) or Keyword.has_key?(opts, :exporter) or
         not is_nil(Config.get([:tracing, :exporter])))
  end

  defp tracing_exporter_opts(opts), do: Keyword.take(opts, [:exporter, :exporter_opts])

  defp trace_name(model) do
    case {model_provider(model), model_identifier(model)} do
      {provider, identifier} when is_binary(provider) and is_binary(identifier) ->
        "#{provider}:#{identifier}"

      {_provider, identifier} when is_binary(identifier) ->
        identifier

      {provider, _identifier} when is_binary(provider) ->
        provider

      _other ->
        model_name(model)
    end
  end

  defp model_tags(model) do
    [:model, model_provider(model)]
    |> Enum.reject(&is_nil/1)
  end

  defp model_start_metadata(model, opts) do
    provider = model_provider(model)
    identifier = model_identifier(model)

    %{}
    |> maybe_put(:model_provider, provider)
    |> maybe_put(:provider, provider)
    |> maybe_put(:ls_provider, provider)
    |> maybe_put(:model_name, identifier)
    |> maybe_put(:model, identifier)
    |> maybe_put(:ls_model_name, identifier)
    |> maybe_put(:ls_temperature, invocation_param(model, opts, :temperature))
    |> maybe_put(:ls_max_tokens, max_tokens(model, opts))
    |> maybe_put(:invocation_params, invocation_params(model, opts))
    |> maybe_put(:tools, tool_names(Keyword.get(opts, :tools)))
    |> maybe_put(:structured_output, structured_output_mode(opts))
  end

  defp model_finish_metadata(model, opts, %Message{} = message, usage) do
    response_metadata = message.response_metadata || %{}

    model_start_metadata(model, opts)
    |> maybe_put(:response_metadata, response_metadata)
    |> maybe_put(
      :finish_reason,
      metadata_first(response_metadata, [:finish_reason, :stop_reason])
    )
    |> maybe_put(:request_id, metadata_first(response_metadata, [:request_id, :id]))
    |> maybe_put(:usage_metadata, usage)
  end

  defp model_outputs(%Message{} = message, usage) do
    %{messages: [message]}
    |> maybe_put(:usage_metadata, usage)
  end

  defp invocation_params(model, opts) do
    model_params =
      model
      |> model_param_map()
      |> Map.take(@safe_model_param_keys)
      |> reject_nil_or_empty()
      |> maybe_merge_model_kwargs(model)

    call_params =
      opts
      |> Keyword.drop(@internal_call_opt_keys)
      |> Keyword.take(@safe_model_param_keys)
      |> Enum.reject(fn {_key, value} -> nil_or_empty?(value) end)
      |> Map.new()

    model_params
    |> Map.merge(call_params)
    |> reject_nil_or_empty()
  end

  defp model_param_map(%{__struct__: _module} = model) do
    model
    |> Map.from_struct()
    |> Map.drop([:api_key, :default_headers, :endpoint, :organization, :project])
  end

  defp model_param_map(model) when is_map(model), do: model
  defp model_param_map(_model), do: %{}

  defp maybe_merge_model_kwargs(params, model) do
    case field_value(model, :model_kwargs) do
      kwargs when is_map(kwargs) and map_size(kwargs) > 0 ->
        Map.put(params, :model_kwargs, kwargs)

      _other ->
        params
    end
  end

  defp invocation_param(model, opts, key) do
    Keyword.get(opts, key, field_value(model, key))
  end

  defp max_tokens(model, opts) do
    Enum.find_value([:max_tokens, :max_completion_tokens, :max_output_tokens], fn key ->
      invocation_param(model, opts, key)
    end)
  end

  defp model_provider(model) do
    (field_value(model, :model_provider) ||
       field_value(model, :provider) ||
       module_provider(model))
    |> normalize_string()
  end

  defp module_provider(%{__struct__: module}) do
    parts = Module.split(module)

    cond do
      "OpenAI" in parts -> "openai"
      "Anthropic" in parts -> "anthropic"
      "XAI" in parts -> "xai"
      "Moonshot" in parts -> "moonshot"
      parts == ["BeamWeaver", "Models", "FakeChatModel"] -> "fake"
      true -> nil
    end
  end

  defp module_provider(_model), do: nil

  defp model_identifier(model) do
    (module_value(model, :model_name) ||
       module_value(model, :model_id) ||
       field_value(model, :model) ||
       field_value(model, :id))
    |> normalize_string()
  end

  defp module_value(%{__struct__: module} = model, function) do
    if function_exported_loaded?(module, function, 1) do
      apply(module, function, [model])
    end
  rescue
    _exception -> nil
  end

  defp module_value(_model, _function), do: nil

  defp field_value(model, key) when is_map(model) do
    MapAccess.get(model, key)
  end

  defp field_value(_model, _key), do: nil

  defp structured_output_mode(opts) do
    cond do
      Keyword.has_key?(opts, :response_format) -> :response_format
      Keyword.has_key?(opts, :structured_output) -> :structured_output
      true -> nil
    end
  end

  defp tool_names(nil), do: nil
  defp tool_names([]), do: nil

  defp tool_names(tools) do
    tools
    |> List.wrap()
    |> Enum.map(&tool_name/1)
    |> Enum.reject(&is_nil/1)
  end

  defp tool_name(%{name: name}), do: normalize_string(name)
  defp tool_name(%{"name" => name}), do: normalize_string(name)
  defp tool_name(%{__struct__: module}), do: module |> Module.split() |> List.last()

  defp tool_name(fun) when is_function(fun) do
    case Function.info(fun, :name) do
      {:name, name} when is_atom(name) -> Atom.to_string(name)
      _other -> nil
    end
  end

  defp tool_name(_tool), do: nil

  defp usage_metadata(%Message{usage_metadata: usage, response_metadata: metadata}) do
    usage = normalize_usage_metadata(usage)

    if map_size(usage) > 0 do
      usage
    else
      metadata
      |> metadata_first([:usage_metadata, :usage, :token_usage])
      |> normalize_usage_metadata()
    end
  end

  defp normalize_usage_metadata(usage) when is_map(usage) do
    %{}
    |> maybe_put(:input_tokens, metadata_first(usage, [:input_tokens, :prompt_tokens]))
    |> maybe_put(:output_tokens, metadata_first(usage, [:output_tokens, :completion_tokens]))
    |> maybe_put(:total_tokens, metadata_first(usage, [:total_tokens]))
    |> maybe_put(:input_cost, metadata_first(usage, [:input_cost]))
    |> maybe_put(:output_cost, metadata_first(usage, [:output_cost]))
    |> maybe_put(:total_cost, metadata_first(usage, [:total_cost]))
    |> maybe_put(:input_token_details, metadata_first(usage, [:input_token_details]))
    |> maybe_put(:output_token_details, metadata_first(usage, [:output_token_details]))
    |> maybe_put(:input_cost_details, metadata_first(usage, [:input_cost_details]))
    |> maybe_put(:output_cost_details, metadata_first(usage, [:output_cost_details]))
    |> Map.take(@usage_metadata_keys)
    |> reject_nil_or_empty()
  end

  defp normalize_usage_metadata(_usage), do: %{}

  defp metadata_first(nil, _keys), do: nil

  defp metadata_first(metadata, keys) when is_map(metadata) do
    Enum.find_value(keys, &Map.get(metadata, &1))
  end

  defp normalize_string(nil), do: nil
  defp normalize_string(value) when is_binary(value), do: value
  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(value), do: to_string(value)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, value) when value == %{}, do: map
  defp maybe_put(map, _key, value) when value == [], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp reject_nil_or_empty(map) do
    Map.reject(map, fn {_key, value} -> nil_or_empty?(value) end)
  end

  defp nil_or_empty?(nil), do: true
  defp nil_or_empty?(%{} = map), do: map_size(map) == 0
  defp nil_or_empty?([]), do: true
  defp nil_or_empty?(_value), do: false
end
