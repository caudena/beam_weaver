defmodule BeamWeaver.Agent.Nodes.Model do
  @moduledoc """
  Graph node that calls a chat model for agent loops.

  The node reads `:messages` from graph state, optionally prepends a system
  prompt for the model call, and appends the assistant response back through the
  graph's `:messages` reducer.
  """

  alias BeamWeaver.Agent.Middleware
  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Agent.Nodes.Model.Prompt
  alias BeamWeaver.Agent.Nodes.Model.Response
  alias BeamWeaver.Agent.StructuredOutput
  alias BeamWeaver.Agent.ToolSet
  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message

  defstruct [
    :model,
    :system_prompt,
    :response_format,
    :agent_name,
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
          agent_name: atom() | String.t() | nil,
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
      agent_name: Keyword.get(opts, :agent_name),
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

    strategy =
      StructuredOutput.effective_strategy(
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
      |> Keyword.merge(structured_provider_opts(strategy))

    messages = Prompt.prompt_messages(request.system_message) ++ request.messages

    with :ok <- ToolSet.validate(tool_set),
         {:ok, response} <- call_model(request.model, messages, opts) do
      case StructuredOutput.handle_model_output(response, strategy) do
        {:ok, model_response} ->
          model_response = Response.maybe_limit_steps_response(request, model_response)

          model_response =
            model_response
            |> Response.put_agent_name(request)
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
  end

  defp call_model(model, messages, opts) do
    if stream_response?(model, opts) do
      ChatModel.trace_call(model, messages, opts, fn ->
        model.__struct__.stream_response(model, messages, opts)
      end)
    else
      ChatModel.invoke(model, messages, opts)
    end
  end

  defp stream_response?(model, opts) do
    Keyword.get(opts, :stream, false) == true and
      function_exported?(model.__struct__, :stream_response, 3)
  end

  defp structured_provider_opts(%StructuredOutput.ProviderStrategy{} = strategy),
    do: StructuredOutput.provider_opts(strategy)

  defp structured_provider_opts(_strategy), do: []
end
