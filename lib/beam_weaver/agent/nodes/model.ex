defmodule BeamWeaver.Agent.Nodes.Model do
  @moduledoc """
  Graph node that calls a chat model for agent loops.

  The node reads `:messages` from graph state, optionally prepends a system
  prompt for the model call, and appends the assistant response back through the
  graph's `:messages` reducer.
  """

  alias BeamWeaver.Agent.Middleware
  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Agent.ModelResponse
  alias BeamWeaver.Agent.Nodes.Model.Prompt
  alias BeamWeaver.Agent.Nodes.Model.Response
  alias BeamWeaver.Agent.StructuredOutput
  alias BeamWeaver.Agent.StructuredOutput.ProviderStrategy
  alias BeamWeaver.Agent.StructuredOutput.ToolStrategy
  alias BeamWeaver.Agent.ToolSet
  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.MessageChunk
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.Tracing

  defstruct [
    :model,
    :system_prompt,
    :response_format,
    :assistant_name,
    tools: [],
    model_opts: [],
    middleware: []
  ]

  @type t :: %__MODULE__{
          model: term(),
          tools: [term()],
          system_prompt: nil | String.t() | Message.t() | [Message.t()],
          model_opts: keyword(),
          middleware: [term()],
          assistant_name: atom() | String.t() | nil,
          response_format: term()
        }

  @spec new(term(), keyword()) :: t()
  def new(model, opts \\ []) do
    %__MODULE__{
      model: model,
      tools: Keyword.get(opts, :tools, []),
      system_prompt: Keyword.get(opts, :system_prompt),
      model_opts: Keyword.get(opts, :model_opts, []),
      middleware: Keyword.get(opts, :middleware, []),
      assistant_name: Keyword.get(opts, :assistant_name),
      response_format: Keyword.get(opts, :response_format)
    }
  end

  @spec invoke(t(), map(), term()) :: map() | {:error, Error.t()}
  def invoke(%__MODULE__{} = node, state, runtime) when is_map(state) do
    with {:ok, messages} <- Prompt.state_messages(state),
         :ok <- Prompt.validate_chat_history(messages),
         {:ok, system_message} <- Prompt.system_message(node.system_prompt, state, runtime),
         {:ok, model} <- resolve_model(node.model, state, runtime),
         request <- %ModelRequest{
           model: model,
           messages: messages,
           system_message: system_message,
           tools: node.tools,
           tool_set: ToolSet.new(node.tools),
           response_format: node.response_format,
           state: state,
           runtime: runtime,
           model_opts: Prompt.model_opts(node, runtime)
         },
         {:ok, response} <- call_model_with_middleware(node.middleware, request) do
      Response.to_update(response)
    end
  end

  def invoke(%__MODULE__{}, _state, _runtime) do
    {:error, Error.new(:invalid_agent_state, "agent model node expected map state")}
  end

  defp resolve_model(model_fun, _state, _runtime) when is_function(model_fun) do
    {:error,
     Error.new(
       :invalid_agent_model,
       "agent model must be a model value; use wrap_model_call middleware for dynamic model selection"
     )}
  end

  defp resolve_model(model, _state, _runtime), do: {:ok, model}

  defp call_model_with_middleware(middleware, %ModelRequest{} = request) do
    wrappers = Enum.filter(middleware, &Middleware.hook?(&1, :wrap_model_call))

    base_handler = fn request ->
      request
      |> execute_model()
      |> Response.normalize_model_result()
    end

    handler =
      Enum.reduce(Enum.reverse(wrappers), base_handler, fn middleware, inner ->
        fn request ->
          Middleware.call_wrapper(middleware, :wrap_model_call, request, inner)
          |> Response.normalize_model_result()
        end
      end)

    handler.(request)
  rescue
    exception ->
      {:error,
       Error.new(:agent_model_error, Exception.message(exception), %{
         exception: inspect(exception.__struct__)
       })}
  end

  defp execute_model(%ModelRequest{} = request) do
    base_tool_set = request.tool_set || ToolSet.new(request.tools)

    {strategy, structured_policy} =
      StructuredOutput.effective_strategy_info(
        request.response_format,
        request.model,
        ToolSet.list(base_tool_set)
      )

    tool_set = ToolSet.add(base_tool_set, StructuredOutput.setup_tools(strategy), source: :model)
    tools = ToolSet.list(tool_set)

    opts =
      request.model_opts
      |> Keyword.put(:tools, tools)
      |> Keyword.put_new(:context, Map.get(request.runtime || %{}, :context))
      |> maybe_put_tool_choice(request.tool_choice)
      |> maybe_force_structured_tool_choice(strategy)
      |> put_structured_output_trace_opts(strategy, structured_policy)
      |> Keyword.merge(structured_provider_opts(strategy))

    messages = Prompt.prompt_messages(request.system_message) ++ request.messages

    trace_structured_output(strategy, structured_policy, request, messages, opts, fn ->
      with :ok <- ToolSet.validate(tool_set),
           {:ok, response} <- call_model(request.model, messages, opts, request.runtime) do
        case StructuredOutput.handle_model_output(response, strategy) do
          {:ok, model_response} ->
            model_response = Response.maybe_limit_steps_response(request, model_response)

            model_response =
              model_response
              |> Response.put_assistant_name(request)
              |> Response.attach_runtime_metadata(tool_set)

            {:ok, model_response}

          {:error, %Error{} = error} ->
            {:error, Response.attach_diagnostics(error, request, messages, opts, response)}
        end
      else
        {:error, %Error{} = error} ->
          {:error, Response.attach_diagnostics(error, request, messages, opts)}

        {:error, reason} ->
          {:error, error} = Response.normalize_model_result({:error, reason})
          {:error, Response.attach_diagnostics(error, request, messages, opts)}
      end
    end)
  end

  defp call_model(model, messages, opts, runtime) do
    cond do
      typed_stream?(model, opts) ->
        ChatModel.trace_call(model, messages, opts, fn ->
          case stream_typed_model(model, messages, opts, runtime) do
            {:error, %Error{type: :unsupported_feature}} = error ->
              if stream_response?(model, opts) do
                model.__struct__.stream_response(model, messages, opts)
              else
                error
              end

            result ->
              result
          end
        end)

      stream_response?(model, opts) ->
        ChatModel.trace_call(model, messages, opts, fn ->
          model.__struct__.stream_response(model, messages, opts)
        end)

      true ->
        ChatModel.invoke(model, messages, opts)
    end
  end

  defp typed_stream?(model, opts) do
    Keyword.get(opts, :stream, false) == true and
      function_exported?(model.__struct__, :stream_typed_events, 3)
  end

  defp stream_response?(model, opts) do
    Keyword.get(opts, :stream, false) == true and
      function_exported?(model.__struct__, :stream_response, 3)
  end

  defp stream_typed_model(model, messages, opts, runtime) do
    with {:ok, events} <- ChatModel.stream_typed_events(model, messages, opts) do
      events
      |> Enum.reduce_while(stream_acc(), &collect_stream_event(&1, &2, runtime))
      |> stream_result()
    end
  end

  defp stream_acc, do: %{message: nil, chunks: [], tokens: [], error: nil}

  defp collect_stream_event(%Envelope{} = envelope, acc, runtime) do
    emit_stream_event(runtime, envelope)
    collect_typed_event(envelope.event, acc)
  end

  defp collect_stream_event(event, acc, runtime) do
    emit_stream_event(runtime, event)
    collect_typed_event(event, acc)
  end

  defp collect_typed_event(%Events.Message{message: %Message{role: :assistant} = message}, acc) do
    {:cont, %{acc | message: message}}
  end

  defp collect_typed_event(%Events.Message{}, acc), do: {:cont, acc}

  defp collect_typed_event(%Events.MessageChunk{chunk: chunk}, acc) do
    case visible_chunk(chunk) do
      nil -> {:cont, acc}
      chunk -> {:cont, %{acc | chunks: [chunk | acc.chunks]}}
    end
  end

  defp collect_typed_event(%Events.Token{text: text}, acc) when is_binary(text) and text != "" do
    {:cont, %{acc | tokens: [text | acc.tokens]}}
  end

  defp collect_typed_event(%Events.Error{error: error}, acc), do: {:halt, %{acc | error: error}}
  defp collect_typed_event(%Events.ToolError{message: message}, acc), do: {:halt, %{acc | error: message}}
  defp collect_typed_event(_event, acc), do: {:cont, acc}

  defp emit_stream_event(%{stream_writer: writer}, %Envelope{event: event, metadata: metadata})
       when is_function(writer, 1) do
    writer.(put_event_metadata(event, metadata))
    :ok
  end

  defp emit_stream_event(%{stream_writer: writer}, event) when is_function(writer, 1) do
    writer.(event)
    :ok
  end

  defp emit_stream_event(_runtime, _event), do: :ok

  defp put_event_metadata(event, metadata) when is_map(metadata) and map_size(metadata) > 0 do
    case Map.fetch(event, :metadata) do
      {:ok, event_metadata} when is_map(event_metadata) ->
        %{event | metadata: Map.merge(event_metadata, metadata)}

      :error ->
        event
    end
  end

  defp put_event_metadata(event, _metadata), do: event

  defp stream_result(%{error: error}) when not is_nil(error), do: {:error, error}
  defp stream_result(%{message: %Message{} = message}), do: {:ok, message}

  defp stream_result(%{chunks: [_ | _] = chunks}) do
    chunks =
      chunks
      |> Enum.reverse()

    case MessageChunk.merge_many(chunks) do
      nil -> stream_text_result([])
      chunk -> {:ok, MessageChunk.to_message(chunk)}
    end
  end

  defp stream_result(%{tokens: tokens}), do: stream_text_result(tokens)

  defp stream_text_result(tokens) do
    text =
      tokens
      |> Enum.reverse()
      |> Enum.join()

    {:ok, Message.assistant(text)}
  end

  defp visible_chunk(%{content: content, tool_call_chunks: tool_call_chunks} = chunk)
       when content in [nil, ""] do
    if List.wrap(tool_call_chunks) != [] do
      %{chunk | content: ""}
    else
      nil
    end
  end

  defp visible_chunk(%{content: content, tool_call_chunks: tool_call_chunks} = chunk)
       when is_list(content) do
    visible_content = Enum.reject(content, &reasoning_block?/1)

    cond do
      visible_content != [] ->
        %{chunk | content: visible_content}

      List.wrap(tool_call_chunks) != [] ->
        %{chunk | content: ""}

      true ->
        nil
    end
  end

  defp visible_chunk(%{content: content} = chunk) when is_list(content) do
    case Enum.reject(content, &reasoning_block?/1) do
      [] -> nil
      visible_content -> %{chunk | content: visible_content}
    end
  end

  defp visible_chunk(chunk), do: chunk

  defp reasoning_block?(%{type: type}) when type in [:reasoning, "reasoning"], do: true
  defp reasoning_block?(_block), do: false

  defp structured_provider_opts(%StructuredOutput.ProviderStrategy{} = strategy),
    do: StructuredOutput.provider_opts(strategy)

  defp structured_provider_opts(_strategy), do: []

  defp maybe_put_tool_choice(opts, nil), do: opts
  defp maybe_put_tool_choice(opts, tool_choice), do: Keyword.put_new(opts, :tool_choice, tool_choice)

  defp maybe_force_structured_tool_choice(opts, %ToolStrategy{}) do
    Keyword.put_new(opts, :tool_choice, :required)
  end

  defp maybe_force_structured_tool_choice(opts, _strategy), do: opts

  defp put_structured_output_trace_opts(opts, %ToolStrategy{schema_specs: specs}, structured_policy) do
    opts
    |> Keyword.put(:structured_output_strategy, :tool)
    |> Keyword.put(:structured_output_tool_names, Enum.map(specs, & &1.name))
    |> put_structured_policy_opts(structured_policy)
  end

  defp put_structured_output_trace_opts(opts, %ProviderStrategy{}, structured_policy) do
    opts
    |> Keyword.put(:structured_output_strategy, :provider)
    |> put_structured_policy_opts(structured_policy)
  end

  defp put_structured_output_trace_opts(opts, _strategy, structured_policy) do
    put_structured_policy_opts(opts, structured_policy)
  end

  defp put_structured_policy_opts(opts, structured_policy) do
    Enum.reduce(StructuredOutput.Policy.to_metadata(structured_policy), opts, fn {key, value}, acc ->
      Keyword.put(acc, key, value)
    end)
  end

  defp trace_structured_output(nil, _structured_policy, _request, _messages, _opts, fun), do: fun.()

  defp trace_structured_output(strategy, structured_policy, request, messages, opts, fun) when is_function(fun, 0) do
    if trace_structured_output?() do
      {:ok, run} =
        Tracing.start_run("RunnableSequence",
          kind: :chain,
          inputs: %{messages: messages},
          tags: [:structured_output],
          metadata: structured_trace_metadata(strategy, structured_policy, request, opts),
          context_metadata: %{}
        )

      try do
        result = fun.()
        finish_structured_run(run, result)
        result
      rescue
        exception ->
          Tracing.fail_run(run, exception)
          reraise exception, __STACKTRACE__
      catch
        kind, reason ->
          Tracing.fail_run(run, %{kind: kind, reason: reason})
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    else
      fun.()
    end
  end

  defp trace_structured_output? do
    not is_nil(Tracing.capture_context())
  end

  defp finish_structured_run(run, {:ok, %ModelResponse{} = response}) do
    Tracing.finish_run(run, outputs: structured_trace_outputs(response))
  end

  defp finish_structured_run(run, {:error, %Error{} = error}) do
    Tracing.fail_run(run, error)
  end

  defp finish_structured_run(run, other) do
    Tracing.finish_run(run, outputs: %{output: inspect(other)})
  end

  defp structured_trace_metadata(strategy, structured_policy, %ModelRequest{} = request, opts) do
    %{
      structured_output: true,
      structured_output_schema: structured_schema_names(strategy),
      structured_output_strategy: structured_strategy_name(strategy),
      provider_strategy: Keyword.get(opts, :structured_output_strategy),
      model: model_name(request.model)
    }
    |> Map.merge(StructuredOutput.Policy.to_metadata(structured_policy))
  end

  defp structured_trace_outputs(%ModelResponse{structured_response: response})
       when not is_nil(response) do
    %{structured_response: response}
  end

  defp structured_trace_outputs(%ModelResponse{} = response) do
    %{
      messages_count: length(response.messages || []),
      structured_response: nil
    }
  end

  defp structured_schema_names(%ToolStrategy{schema_specs: specs}) do
    Enum.map(specs, & &1.name)
  end

  defp structured_schema_names(%ProviderStrategy{schema_spec: nil}), do: []
  defp structured_schema_names(%ProviderStrategy{schema_spec: spec}), do: [spec.name]
  defp structured_schema_names(_strategy), do: []

  defp structured_strategy_name(%ToolStrategy{}), do: :tool
  defp structured_strategy_name(%ProviderStrategy{}), do: :provider

  defp model_name(%{model: model}) when is_binary(model), do: model

  defp model_name(%{__struct__: module} = model) do
    cond do
      function_exported?(module, :model_name, 1) -> module.model_name(model)
      function_exported?(module, :model_id, 1) -> module.model_id(model)
      true -> inspect(module)
    end
  rescue
    _exception -> inspect(model)
  end

  defp model_name(model), do: inspect(model)
end
