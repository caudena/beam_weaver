defmodule BeamWeaver.Agent.Middleware.ToolError do
  @moduledoc """
  Decides what the model reads when a tool fails, or stops the run instead.

  Without it, a failed tool call reaches the model as a tool message that
  starts with `Tool error:` and lists the call's arguments. `:on_error` takes
  the `%BeamWeaver.Core.Error{}` and the `BeamWeaver.Agent.ToolCallRequest` and
  returns what the model reads instead, as text or content blocks, or `nil`,
  which stops the run with the error. Write what the model needs to go on,
  rather than the error's message, which may carry internal details.

  Arguments the model got wrong (`:invalid_input`) and calls to a tool the
  agent doesn't have (`:unknown_tool`) still reach the model as they are, so
  it can fix the call.

  Options:

    * `:on_error` - the two-argument function. Required.
    * `:tools` - the tools whose failures it handles, as names or tools. All
      tools when left out.

  It doesn't retry. To retry first, list `BeamWeaver.Agent.Middleware.ToolRetry`
  after it, with the default `on_failure: :error`.
  """

  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.Middleware.Helpers
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message

  @model_fixable [:invalid_input, :unknown_tool]

  defstruct [:on_error, tools: nil]

  @type t :: %__MODULE__{
          on_error: (Error.t(), BeamWeaver.Agent.ToolCallRequest.t() -> String.t() | list() | nil),
          tools: MapSet.t(String.t()) | nil
        }

  def new(opts \\ []) do
    on_error = Keyword.get(opts, :on_error)

    unless is_function(on_error, 2) do
      raise ArgumentError, "ToolError needs :on_error, a function of the error and the tool call request"
    end

    %__MODULE__{on_error: on_error, tools: opts |> Keyword.get(:tools) |> Helpers.tool_names()}
  end

  @impl true
  def name(_middleware), do: :tool_error

  @impl true
  def wrap_tool_call(%__MODULE__{} = middleware, request, handler) do
    result = handler.(request)

    with true <- handles?(middleware, request),
         %Error{type: type} = error when type not in @model_fixable <- Helpers.tool_failure(result) do
      case middleware.on_error.(error, request) do
        # The tool node fails the step, and with it the run, on this signal.
        nil ->
          throw({:beam_weaver_graph_error, error})

        content when is_binary(content) or is_list(content) ->
          error_message(content, error, request)

        other ->
          raise ArgumentError, "ToolError's on_error must return text, content blocks or nil, got #{inspect(other)}"
      end
    else
      _not_handled -> result
    end
  end

  defp handles?(%__MODULE__{tools: nil}, _request), do: true
  defp handles?(%__MODULE__{tools: tools}, request), do: MapSet.member?(tools, call_name(request))

  defp error_message(content, %Error{} = error, request) do
    Message.tool(content,
      tool_call_id: Helpers.tool_call_id(request.tool_call),
      name: call_name(request),
      status: "error",
      metadata: %{status: "error", error_type: error.type, error_message: error.message}
    )
  end

  defp call_name(%{tool_call: call}), do: Map.get(call, :name)
end
