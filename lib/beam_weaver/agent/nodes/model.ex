defmodule BeamWeaver.Agent.Nodes.Model do
  @moduledoc false

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
  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages
  alias BeamWeaver.Core.Messages.MessageChunk
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.Tracing

  defstruct [
    :model,
    :system_prompt,
    :response_format,
    :assistant_name,
    :final_instruction,
    :step_costs,
    tools: [],
    model_opts: [],
    middleware: [],
    save_tool_set: true,
    structured_output: false
  ]

  @type t :: %__MODULE__{
          model: term(),
          tools: [term()],
          system_prompt: nil | String.t() | Message.t() | [Message.t()],
          model_opts: keyword(),
          middleware: [term()],
          assistant_name: atom() | String.t() | nil,
          response_format: term(),
          final_instruction: String.t() | nil,
          step_costs: map() | nil,
          save_tool_set: boolean(),
          structured_output: boolean()
        }

  @spec new(term(), keyword()) :: t()
  def new(model, opts), do: struct(__MODULE__, Keyword.put(opts, :model, model))

  @spec invoke(t(), map(), term()) :: map() | {:error, Error.t()}
  def invoke(%__MODULE__{} = node, state, runtime) when is_map(state) do
    with {:ok, history} <- Prompt.state_messages(state),
         messages = Prompt.answer_invalid_tool_calls(history),
         :ok <- Prompt.validate_chat_history(messages),
         {:ok, system_message} <- Prompt.system_message(node.system_prompt),
         request <- %ModelRequest{
           model: node.model,
           messages: with_final_instruction(messages, node.final_instruction),
           system_message: system_message,
           tools: node.tools,
           tool_set: ToolSet.new(node.tools),
           response_format: node.response_format,
           state: state,
           runtime: runtime,
           model_opts: Prompt.model_opts(node, runtime)
         },
         {:ok, response} <- call_model_with_middleware(node, request) do
      response
      |> forget_tool_set(node)
      |> Response.to_update(
        structured_output: node.structured_output,
        history: if(messages != history, do: messages)
      )
    end
  end

  # The tools node runs the tools of the agent loop's latest model call. The
  # structured-response call after the loop offers only its own tool, which
  # no tools node runs, so it leaves the loop's tool set in place.
  defp forget_tool_set(%ModelResponse{} = response, %__MODULE__{save_tool_set: false}),
    do: %{response | tool_set: nil}

  defp forget_tool_set(response, _node), do: response

  # Middleware such as StructuredOutputRetry find the reply that failed the
  # structured-output checks in `details.failed_reply`. It stays inside the
  # model call: the error the run returns carries only the redacted diagnostics.
  defp put_failed_reply(%Error{} = error, %Message{} = reply),
    do: %{error | details: Map.put(error.details || %{}, :failed_reply, reply)}

  defp drop_failed_reply({:error, %Error{details: %{failed_reply: _reply} = details} = error}),
    do: {:error, %{error | details: Map.delete(details, :failed_reply)}}

  defp drop_failed_reply(result), do: result

  # A call that must answer the conversation so far, such as the structured
  # response after a tool loop, would otherwise end on the assistant's own turn,
  # which several providers reject. The instruction goes to this one request;
  # it is not added to the state.
  defp with_final_instruction(messages, nil), do: messages

  defp with_final_instruction(messages, instruction) do
    case List.last(messages) do
      %Message{role: :assistant} -> messages ++ [Message.user(instruction)]
      _other -> messages
    end
  end

  defp call_model_with_middleware(%__MODULE__{} = node, %ModelRequest{} = request) do
    wrappers = Enum.filter(node.middleware, &Middleware.hook?(&1, :wrap_model_call))

    base_handler = fn request ->
      request
      |> execute_model(node.step_costs)
      |> Response.normalize_model_result()
    end

    handler =
      Enum.reduce(Enum.reverse(wrappers), base_handler, fn middleware, inner ->
        fn request ->
          Middleware.call_wrapper(middleware, :wrap_model_call, request, inner)
          |> Response.normalize_model_result()
        end
      end)

    request
    |> handler.()
    |> drop_failed_reply()
  rescue
    exception ->
      {:error,
       Error.new(:agent_model_error, Exception.message(exception), %{
         exception: inspect(exception.__struct__)
       })}
  end

  defp execute_model(%ModelRequest{} = request, step_costs) do
    base_tool_set = request.tool_set || ToolSet.new(request.tools)

    {strategy, structured_policy} =
      StructuredOutput.effective_strategy_info(
        request.response_format,
        request.model,
        ToolSet.list(base_tool_set)
      )

    tool_set = ToolSet.add(base_tool_set, StructuredOutput.setup_tools(strategy), source: :model)
    tools = provider_tools(request.model_opts) ++ ToolSet.list(tool_set)

    opts =
      request.model_opts
      |> Keyword.put(:tools, tools)
      |> Keyword.put_new(:context, Map.get(request.runtime || %{}, :context))
      |> maybe_put_tool_choice(request.tool_choice)
      |> maybe_force_structured_tool_choice(strategy, request.model)
      |> put_structured_output_trace_opts(strategy, structured_policy)
      |> Keyword.merge(structured_provider_opts(strategy))

    messages = Prompt.prompt_messages(request.system_message) ++ request.messages

    trace_structured_output(strategy, structured_policy, request, messages, opts, fn ->
      with :ok <- ToolSet.validate(tool_set),
           {:ok, response} <- call_model(request.model, messages, opts, request.runtime) do
        case StructuredOutput.handle_model_output(response, strategy, request.messages) do
          {:ok, model_response} ->
            {:ok,
             request
             |> Response.maybe_limit_steps_response(model_response, step_costs)
             |> Response.put_assistant_name(request)
             |> Response.attach_runtime_metadata(tool_set)}

          {:error, %Error{} = error} ->
            error = Response.attach_diagnostics(error, request, messages, opts, response)
            {:error, put_failed_reply(error, response)}
        end
      else
        {:error, _reason} = result ->
          {:error, error} = Response.normalize_model_result(result)
          {:error, Response.attach_diagnostics(error, request, messages, opts)}
      end
    end)
  end

  # A model call that fails sends a `Debug` event, `%{type: :model_call_failed,
  # error: error}`, to the run's stream: the text the call streamed is not
  # part of the answer. The error goes back to the middleware, which may call
  # a model again (`ModelRetry`, `ModelFallback`); only a run that fails ends
  # with an `Error` event.
  defp call_model(model, messages, opts, runtime) do
    case send_model_call(model, messages, opts, runtime) do
      {:error, _reason} = result ->
        {:error, error} = Response.normalize_model_result(result)
        emit_stream_event(runtime, %Events.Debug{payload: %{type: :model_call_failed, error: error}})
        result

      result ->
        result
    end
  end

  defp send_model_call(model, messages, opts, runtime) do
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
    stream?(model, opts) and function_exported?(model.__struct__, :stream_typed_events, 3)
  end

  defp stream_response?(model, opts) do
    stream?(model, opts) and function_exported?(model.__struct__, :stream_response, 3)
  end

  # A model created with `stream: true` streams unless the call says otherwise.
  defp stream?(model, opts), do: Keyword.get(opts, :stream, Map.get(model, :streaming, false)) == true

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

  defp emit_stream_event(runtime, %Envelope{event: event, metadata: metadata}) do
    emit_stream_event(runtime, put_event_metadata(event, metadata))
  end

  # The collector uses the provider's complete message as its result. The graph
  # publishes that result after model middleware, so forwarding it here as well
  # would emit the same assistant message twice.
  defp emit_stream_event(_runtime, %Events.Message{message: %Message{role: :assistant}}), do: :ok

  # A model stream's `Error` fails the call, not the run (see `call_model/4`).
  defp emit_stream_event(_runtime, %Events.Error{}), do: :ok

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

  defp stream_result(%{chunks: [_ | _] = chunks, tokens: tokens}) do
    case MessageChunk.merge_many(Enum.reverse(chunks)) do
      nil ->
        stream_text_result([])

      chunk ->
        message = MessageChunk.to_message(chunk)

        if Message.text(message) == "" and tokens != [] do
          text = tokens |> Enum.reverse() |> Enum.join()

          chunk
          |> MessageChunk.merge(Messages.ai_chunk(text))
          |> MessageChunk.to_message()
          |> then(&{:ok, &1})
        else
          {:ok, message}
        end
    end
  end

  defp stream_result(%{tokens: tokens}), do: stream_text_result(tokens)

  defp stream_text_result(tokens), do: {:ok, Message.assistant(tokens |> Enum.reverse() |> Enum.join())}

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
    visible_content = Enum.reject(content, &hidden_reasoning_block?/1)

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
    case Enum.reject(content, &hidden_reasoning_block?/1) do
      [] -> nil
      visible_content -> %{chunk | content: visible_content}
    end
  end

  defp visible_chunk(chunk), do: chunk

  defp hidden_reasoning_block?(block) do
    ContentBlock.reasoning?(block) and not ContentBlock.replayable_reasoning?(block)
  end

  defp structured_provider_opts(%StructuredOutput.ProviderStrategy{} = strategy),
    do: StructuredOutput.provider_opts(strategy)

  defp structured_provider_opts(_strategy), do: []

  defp maybe_put_tool_choice(opts, nil), do: opts
  defp maybe_put_tool_choice(opts, tool_choice), do: Keyword.put_new(opts, :tool_choice, tool_choice)

  # The tool strategy asks the model to call a tool, unless the model rejects a
  # forced tool choice (such as Kimi with thinking on); the request then only
  # offers the structured-output tool.
  defp maybe_force_structured_tool_choice(opts, %ToolStrategy{}, model) do
    if forced_tool_choice?(model, opts), do: Keyword.put_new(opts, :tool_choice, :required), else: opts
  end

  defp maybe_force_structured_tool_choice(opts, _strategy, _model), do: opts

  defp forced_tool_choice?(%{__struct__: module} = model, opts) do
    cond do
      function_exported?(module, :forced_tool_choice?, 2) -> module.forced_tool_choice?(model, opts)
      is_struct(Map.get(model, :model)) -> forced_tool_choice?(model.model, opts)
      true -> true
    end
  end

  defp forced_tool_choice?(_model, _opts), do: true

  # Tool declarations in the model options, such as a provider's built-in web
  # search, are offered next to the agent's tools. The provider runs them, so
  # they are not part of the agent's tool set.
  defp provider_tools(model_opts) do
    model_opts
    |> Keyword.get(:tools, [])
    |> List.wrap()
    |> Enum.filter(&(is_map(&1) and not is_struct(&1)))
  end

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
    if Tracing.capture_context() do
      Tracing.Runner.run(
        "RunnableSequence",
        [
          kind: :chain,
          inputs: %{messages: messages},
          tags: [:structured_output],
          metadata: structured_trace_metadata(strategy, structured_policy, request, opts),
          context_metadata: %{}
        ],
        [],
        fun,
        fn run, result ->
          finish_structured_run(run, result)
          result
        end
      )
    else
      fun.()
    end
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
  end

  defp model_name(model), do: inspect(model)
end
