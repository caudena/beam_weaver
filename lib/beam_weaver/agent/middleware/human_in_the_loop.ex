defmodule BeamWeaver.Agent.Middleware.HumanInTheLoop do
  @moduledoc """
  Human review middleware for agent tool calls.

  After the model emits tool calls, reviewable calls are batched into a single
  graph interrupt. On resume, decisions approve, edit, reject, or respond to
  each interrupted call while preserving the original tool-call IDs.

  With `interrupt_mode: :per_call`, each reviewable call pauses on its own
  instead, as it starts: every call of the turn runs as a task of its own, and
  each reviewable one raises an interrupt whose value is a `"tool_approval"`
  request with the call, its description, the decisions it allows and the
  arguments schema an edit must match. Answer each with one decision, keyed by
  the interrupt's id, all at once or one at a time; the other calls run
  without waiting and don't run again. An edit keeps the tool and replaces its
  arguments. An answer that doesn't fit fails the resume with
  `:invalid_human_decision`, and the call waits for another answer. The run
  pauses on the first interrupt, and its `interrupts` lists them all.

  An edit leaves the model's call in its message and runs the reviewer's call
  in its place, which may name another tool. The result starts with
  `:edit_notice`, which tells the model a reviewer replaced the call and what
  ran instead. A rejection answers the call with a tool message that says the
  user rejected it, with the reviewer's reason when there is one.

  `interrupt_on` maps tool names to `true`, `false`, or a map of rules. A rule
  map always turns review on: it allows all four decisions unless
  `allowed_decisions` lists fewer. Edited arguments must match the rule's
  `args_schema`, when it has one, and the tool's own input schema.
  """

  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.Middleware.Helpers
  alias BeamWeaver.Agent.State
  alias BeamWeaver.Agent.ToolCallRequest
  alias BeamWeaver.Agent.ToolSet
  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.MapShape

  @decisions [:approve, :edit, :reject, :respond]

  @edit_notice "Note: a human reviewer replaced this tool call before it ran. The call recorded in " <>
                 "your message is the one you produced, not the one that executed. This was " <>
                 "intentional and authorized. Do not re-issue your original call."

  # The reviewer's call for each edited tool call id, from `after_model` to
  # `wrap_tool_call`.
  @edits :hitl_edited_tool_calls

  defmodule Decision do
    @moduledoc "Typed HITL resume decision."
    defstruct [:type, :message, :edited_action]
  end

  defstruct interrupt_on: %{},
            interrupt_mode: :all,
            description_prefix: "Tool execution requires approval",
            edit_notice: @edit_notice,
            tools: %{}

  @type t :: %__MODULE__{
          interrupt_on: map(),
          interrupt_mode: :all | :first | :per_call,
          description_prefix: String.t(),
          edit_notice: String.t() | nil,
          tools: map()
        }

  @doc """
  Builds the middleware. Agents build it from their `interrupt_on`
  declaration.

    * `:interrupt_on` - tool names mapped to `true`, `false` or a map of
      rules with `allowed_decisions`, `when`, `description` and `args_schema`.
    * `:interrupt_mode` - `:all` (the default) puts every matching call of a
      model turn in one review; `:first` reviews only the first one;
      `:per_call` reviews each matching call on its own, as it starts. In
      `:per_call`, list this middleware before tool retry and error
      middleware, so the review comes first.
    * `:description_prefix` - the first line of the default description.
    * `:edit_notice` - the text that starts the result of an edited call,
      followed by the call that ran; `nil` adds nothing.

  Raises `ArgumentError` for a rule it can't read, such as an unknown
  decision, rather than skipping the review.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    interrupt_on =
      opts
      |> Keyword.get(:interrupt_on, %{})
      |> normalize_interrupt_on()

    %__MODULE__{
      interrupt_on: interrupt_on,
      interrupt_mode: opts |> Keyword.get(:interrupt_mode, :all) |> normalize_interrupt_mode!(),
      description_prefix: Keyword.get(opts, :description_prefix, "Tool execution requires approval"),
      edit_notice: Keyword.get(opts, :edit_notice, @edit_notice),
      tools: tool_map(Keyword.get(opts, :tools, []))
    }
  end

  # The agent compiler hands the agent's tools to every review middleware, so
  # edited arguments can be checked against the tool's own input schema.
  @doc false
  @spec bind_tools([term()], [term()]) :: [term()]
  def bind_tools(middleware, tools) when is_list(middleware) do
    Enum.map(middleware, fn
      %__MODULE__{} = review -> %{review | tools: Map.merge(tool_map(tools), review.tools)}
      other -> other
    end)
  end

  @impl true
  def name(_middleware), do: :human_in_the_loop

  @impl true
  def requires_checkpointer?(_middleware), do: true

  @impl true
  def state_schema(_middleware),
    do: %{@edits => Graph.private_channel(BeamWeaver.Graph.Channels.LastValue, checkpoint: true)}

  @impl true
  def after_model(%__MODULE__{interrupt_mode: :per_call}, _state, _runtime), do: nil

  def after_model(%__MODULE__{} = middleware, state, runtime) do
    with {:ok, messages} <- state_messages(state) do
      case Helpers.last_message(messages, :assistant) do
        %Message{tool_calls: calls} = ai_message when is_list(calls) and calls != [] ->
          review = review_requests(middleware, calls, state, runtime)

          if review.action_requests == [] do
            clear_edits(state)
          else
            process_review(middleware, ai_message, calls, review)
          end

        _message ->
          nil
      end
    end
  end

  # An earlier turn's edits must not apply to this turn's calls.
  defp clear_edits(state) do
    if (Map.get(state, @edits) || %{}) != %{}, do: %{@edits => %{}}
  end

  @impl true
  def wrap_tool_call(%__MODULE__{interrupt_mode: :per_call} = middleware, %ToolCallRequest{} = request, handler) do
    call = request.tool_call
    config = Map.get(middleware.interrupt_on, tool_call_name(call))

    if config && reviewable?(config, call, request.state, request.runtime),
      do: review_call(middleware, request, config, handler),
      else: handler.(request)
  end

  def wrap_tool_call(%__MODULE__{} = middleware, %ToolCallRequest{} = request, handler) do
    case reviewer_call(request) do
      nil ->
        handler.(request)

      edit ->
        call = request.tool_call

        tool =
          if edit.name == tool_call_name(call),
            do: request.tool,
            else: ToolSet.get(request.tool_set, edit.name)

        request
        |> ToolCallRequest.override(tool_call: Map.merge(call, edit), tool: tool)
        |> handler.()
        |> edited_result(middleware, call, edit)
    end
  end

  # A call's own review: the run pauses until the reviewer answers it, then
  # the call runs, runs with the reviewer's arguments, or is answered instead.
  # The tool node fails the step on an answer that doesn't fit, and the call
  # waits for another.
  defp review_call(middleware, request, config, handler) do
    call = request.tool_call

    with {:ok, approval} <- approval_request(middleware, request, config),
         answer = Graph.interrupt(approval),
         {:ok, decision} <- call_decision(middleware, answer, call, config) do
      case decision do
        :approve ->
          handler.(request)

        {:edit, edit} ->
          request
          |> ToolCallRequest.override(tool_call: Map.merge(call, edit))
          |> handler.()
          |> edited_result(middleware, call, edit)

        %Message{} = message ->
          message
      end
    else
      {:error, %Error{} = error} -> throw({:beam_weaver_graph_error, error})
    end
  end

  defp approval_request(middleware, request, config) do
    call = request.tool_call

    if is_nil(Helpers.tool_call_id(call)) do
      {:error,
       Error.new(:invalid_tool_call, "tool call has no id, so its result can't be matched to it", %{
         tool: tool_call_name(call)
       })}
    else
      {action, review} = create_action_and_config(middleware, call, config, request.state, request.runtime)

      approval = %{
        type: "tool_approval",
        tool_call_id: Helpers.tool_call_id(call),
        name: action.name,
        args: action.args,
        description: action.description,
        allowed_decisions: review.allowed_decisions
      }

      # What an edit's arguments must match: the rule's schema, or the tool's.
      case :edit in config.allowed_decisions &&
             (config.args_schema || (request.tool && Tool.input_schema(request.tool))) do
        schema when is_map(schema) -> {:ok, Map.put(approval, :args_schema, schema)}
        _no_edits -> {:ok, approval}
      end
    end
  end

  # One decision for one call. An edit keeps the call's tool.
  defp call_decision(middleware, answer, call, config) when is_map(answer) do
    case process_decision(middleware, answer, call, config) do
      {:ok, {:edit, %{name: name}}} = result ->
        if name == tool_call_name(call),
          do: result,
          else:
            {:error,
             Error.new(:invalid_human_decision, "an edit must keep the tool it reviews", %{
               tool: tool_call_name(call),
               edited_tool: name
             })}

      result ->
        result
    end
  end

  defp call_decision(_middleware, answer, call, config),
    do: invalid_decision(answer, call, Map.fetch!(config, :allowed_decisions))

  defp reviewer_call(%ToolCallRequest{state: state, tool_call: call}) when is_map(state) do
    (Map.get(state, @edits) || %{}) |> Map.get(Helpers.tool_call_id(call))
  end

  defp reviewer_call(_request), do: nil

  # The result answers the model's call, so it keeps that call's name, which
  # Gemini matches against the call, and says what ran instead.
  defp edited_result(%Message{role: :tool} = message, middleware, call, edit) do
    if message.tool_call_id == Helpers.tool_call_id(call),
      do: %{message | name: tool_call_name(call), content: with_notice(message.content, middleware, edit)},
      else: message
  end

  defp edited_result(%Command{update: update} = command, middleware, call, edit) when is_map(update) do
    case Enum.find([:messages, "messages"], &is_list(Map.get(update, &1))) do
      nil ->
        command

      key ->
        messages = Enum.map(Map.fetch!(update, key), &edited_result(&1, middleware, call, edit))
        %{command | update: Map.put(update, key, messages)}
    end
  end

  defp edited_result(results, middleware, call, edit) when is_list(results),
    do: Enum.map(results, &edited_result(&1, middleware, call, edit))

  defp edited_result(result, _middleware, _call, _edit), do: result

  defp with_notice(content, %__MODULE__{edit_notice: nil}, _edit), do: content

  defp with_notice(content, middleware, edit) do
    args =
      case BeamWeaver.JSON.encode(edit.args) do
        {:ok, json} -> json
        {:error, _error} -> inspect(edit.args)
      end

    notice = "#{middleware.edit_notice} Executed instead: #{edit.name} with arguments #{args}."

    case content do
      content when content in ["", nil, []] -> notice
      content when is_binary(content) -> "#{notice}\n\nTool response:\n#{content}"
      blocks when is_list(blocks) -> [ContentBlock.text("#{notice}\n\nTool response:") | blocks]
      content -> content
    end
  end

  defp process_review(middleware, ai_message, calls, review) do
    with {:ok, decisions} <- decisions(Graph.interrupt(Map.take(review, [:action_requests, :review_configs]))) do
      apply_decisions(middleware, ai_message, calls, review.interrupt_indices, decisions)
    end
  end

  defp review_requests(middleware, calls, state, runtime) do
    reducer = fn {call, idx}, acc ->
      name = tool_call_name(call)

      case Map.get(middleware.interrupt_on, name) do
        nil ->
          {:cont, acc}

        config ->
          if reviewable?(config, call, state, runtime) do
            {action_request, review_config} =
              create_action_and_config(middleware, call, config, state, runtime)

            acc = %{
              action_requests: acc.action_requests ++ [action_request],
              review_configs: acc.review_configs ++ [review_config],
              interrupt_indices: acc.interrupt_indices ++ [{idx, config}]
            }

            if middleware.interrupt_mode == :first, do: {:halt, acc}, else: {:cont, acc}
          else
            {:cont, acc}
          end
      end
    end

    calls
    |> Enum.with_index()
    |> Enum.reduce_while(%{action_requests: [], review_configs: [], interrupt_indices: []}, reducer)
  end

  defp reviewable?(config, call, state, runtime) do
    case Map.get(config, :when) || Map.get(config, :predicate) do
      nil -> true
      predicate when is_function(predicate, 3) -> predicate.(call, state, runtime) == true
      predicate when is_function(predicate, 2) -> predicate.(call, state) == true
      predicate when is_function(predicate, 1) -> predicate.(call) == true
      _other -> true
    end
  end

  defp create_action_and_config(middleware, call, config, state, runtime) do
    name = tool_call_name(call)
    args = tool_call_args(call)

    description =
      case Map.get(config, :description) do
        nil ->
          "#{middleware.description_prefix}\n\nTool: #{name}\nArgs: #{inspect(args)}"

        description when is_binary(description) ->
          description

        description when is_function(description, 3) ->
          description.(call, state, runtime)

        description when is_function(description, 2) ->
          description.(call, state)
      end

    action_request = %{name: name, args: args, description: description}

    review_config =
      MapShape.put_present(
        %{action_name: name, allowed_decisions: Enum.map(Map.fetch!(config, :allowed_decisions), &Atom.to_string/1)},
        :args_schema,
        Map.get(config, :args_schema)
      )

    {action_request, review_config}
  end

  defp decisions(%{decisions: decisions}) when is_list(decisions), do: {:ok, decisions}
  defp decisions(%{"decisions" => decisions}) when is_list(decisions), do: {:ok, decisions}

  defp decisions(other) do
    {:error,
     Error.new(:invalid_human_decision, "HITL resume value must include decisions", %{
       resume: inspect(other)
     })}
  end

  defp apply_decisions(_middleware, _ai_message, _calls, interrupt_indices, decisions)
       when length(decisions) != length(interrupt_indices) do
    {:error,
     Error.new(
       :invalid_human_decision,
       "number of human decisions does not match number of interrupted tool calls",
       %{decisions: length(decisions), interrupted_tool_calls: length(interrupt_indices)}
     )}
  end

  defp apply_decisions(middleware, ai_message, calls, interrupt_indices, decisions) do
    decision_by_index =
      interrupt_indices
      |> Enum.zip(decisions)
      |> Map.new(fn {{idx, config}, decision} -> {idx, {config, decision}} end)

    calls
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], %{}}, fn {call, idx}, {:ok, synthetic, edits} ->
      case Map.fetch(decision_by_index, idx) do
        :error ->
          {:cont, {:ok, synthetic, edits}}

        {:ok, {config, decision}} ->
          case process_decision(middleware, decision, call, config) do
            {:ok, {:edit, edit}} -> {:cont, {:ok, synthetic, Map.put(edits, Helpers.tool_call_id(call), edit)}}
            {:ok, :approve} -> {:cont, {:ok, synthetic, edits}}
            {:ok, %Message{} = message} -> {:cont, {:ok, synthetic ++ [message], edits}}
            {:error, %Error{} = error} -> {:halt, {:error, error}}
          end
      end
    end)
    |> case do
      # Written every review, so an earlier review's edits don't linger.
      {:ok, synthetic_messages, edits} -> %{@edits => edits, messages: [ai_message | synthetic_messages]}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp process_decision(middleware, decision, call, config) do
    type = decision_type(decision)
    allowed = Map.fetch!(config, :allowed_decisions)

    cond do
      type not in allowed ->
        invalid_decision(decision, call, allowed)

      type == :approve ->
        {:ok, :approve}

      type == :edit ->
        edit_decision(middleware, decision, call, config)

      type == :reject ->
        {:ok, reject_message(decision, call)}

      type == :respond ->
        case decision_message(decision) do
          nil -> invalid_decision(decision, call, allowed)
          message -> {:ok, respond_message(message, call)}
        end
    end
  end

  # The model's call stays in its message; `wrap_tool_call` runs this one.
  defp edit_decision(middleware, decision, call, config) do
    with {:ok, edited_action} <- edited_action(decision),
         {:ok, edited_call} <- edited_call(call, edited_action),
         :ok <- validate_edited_args(middleware, edited_call, config) do
      {:ok, {:edit, Map.take(edited_call, [:name, :args])}}
    end
  end

  defp edited_action(%{edited_action: action}) when is_map(action), do: {:ok, action}
  defp edited_action(%{"edited_action" => action}) when is_map(action), do: {:ok, action}

  defp edited_action(decision) do
    {:error,
     Error.new(:invalid_human_decision, "edit decision must include edited_action", %{
       decision: inspect(decision)
     })}
  end

  defp edited_call(call, action) do
    name = Map.get(action, :name, Map.get(action, "name"))
    args = Map.get(action, :args, Map.get(action, "args", %{}))

    if is_binary(name) and is_map(args) do
      {:ok, %{id: Helpers.tool_call_id(call), name: name, args: args}}
    else
      {:error,
       Error.new(:invalid_human_decision, "edited_action must include name and args", %{
         edited_action: inspect(action)
       })}
    end
  end

  defp validate_edited_args(middleware, edited_call, config) do
    tool_schema =
      case Map.fetch(middleware.tools, edited_call.name) do
        {:ok, tool} -> Tool.input_schema(tool)
        :error -> nil
      end

    [Map.get(config, :args_schema), tool_schema]
    |> Enum.filter(&is_map/1)
    |> Enum.reduce_while(:ok, fn schema, :ok ->
      case Tool.validate_input(schema, edited_call.args) do
        :ok -> {:cont, :ok}
        {:error, %Error{} = error} -> {:halt, {:error, %{error | type: :invalid_human_decision}}}
      end
    end)
  end

  defp reject_message(decision, call) do
    content =
      case decision_message(decision) do
        reason when reason in [nil, ""] ->
          "User rejected the tool call for `#{tool_call_name(call)}` with id #{Helpers.tool_call_id(call)}. " <>
            "The tool was not executed. Do not retry this tool call unless the user explicitly requests it."

        reason ->
          "User rejected the tool call for `#{tool_call_name(call)}` with reason: #{reason}"
      end

    Message.tool(content,
      name: tool_call_name(call),
      tool_call_id: Helpers.tool_call_id(call),
      status: "error",
      metadata: %{status: "error"}
    )
  end

  defp respond_message(content, call) do
    Message.tool(content,
      name: tool_call_name(call),
      tool_call_id: Helpers.tool_call_id(call),
      status: "success",
      metadata: %{status: "success"}
    )
  end

  defp invalid_decision(decision, call, allowed) do
    {:error,
     Error.new(:invalid_human_decision, "human decision is not allowed for tool", %{
       decision: inspect(decision),
       tool: tool_call_name(call),
       allowed_decisions: allowed
     })}
  end

  defp state_messages(state) do
    case State.messages(state) do
      messages when is_list(messages) -> {:ok, messages}
      _other -> {:error, Error.new(:invalid_agent_state, "agent state messages must be a list")}
    end
  end

  defp normalize_interrupt_on(interrupt_on) when is_map(interrupt_on) do
    interrupt_on
    |> Enum.map(fn {tool_name, config} -> {to_string(tool_name), normalize_config(tool_name, config)} end)
    |> Enum.reject(fn {_tool, config} -> is_nil(config) end)
    |> Map.new()
  end

  defp normalize_interrupt_on(interrupt_on) when is_list(interrupt_on) do
    if Enum.all?(interrupt_on, &match?({_tool, _config}, &1)),
      do: interrupt_on |> Map.new() |> normalize_interrupt_on(),
      else: invalid_interrupt_on!(interrupt_on)
  end

  defp normalize_interrupt_on(value) when value in [nil, false], do: %{}
  defp normalize_interrupt_on(interrupt_on), do: invalid_interrupt_on!(interrupt_on)

  defp invalid_interrupt_on!(interrupt_on) do
    raise ArgumentError,
          "interrupt_on must map tool names to true, false or a map of rules, got #{inspect(interrupt_on)}"
  end

  # A rule map turns review on, like `true`; `allowed_decisions` only narrows
  # what the reviewer may answer.
  defp normalize_config(_tool, value) when value in [false, nil], do: nil
  defp normalize_config(tool, true), do: normalize_config(tool, %{})

  defp normalize_config(tool, config) when is_list(config) do
    if Keyword.keyword?(config),
      do: normalize_config(tool, Map.new(config)),
      else: invalid_rule!(tool, config)
  end

  defp normalize_config(tool, config) when is_map(config) do
    %{
      :when => rule_value(config, :when),
      allowed_decisions: allowed_decisions!(tool, rule_value(config, :allowed_decisions)),
      description: rule_value(config, :description),
      args_schema: rule_value(config, :args_schema),
      predicate: rule_value(config, :predicate)
    }
  end

  defp normalize_config(tool, config), do: invalid_rule!(tool, config)

  defp allowed_decisions!(_tool, nil), do: @decisions

  defp allowed_decisions!(tool, decisions) do
    decisions = List.wrap(decisions)
    unknown = Enum.reject(decisions, &decision_atom/1)

    cond do
      decisions == [] ->
        raise ArgumentError,
              "interrupt_on rule for #{inspect(to_string(tool))} must allow at least one decision"

      unknown != [] ->
        raise ArgumentError,
              "interrupt_on rule for #{inspect(to_string(tool))} has unknown decisions " <>
                "#{inspect(unknown)}; use :approve, :edit, :reject or :respond"

      true ->
        decisions |> Enum.map(&decision_atom/1) |> Enum.uniq()
    end
  end

  defp invalid_rule!(tool, config) do
    raise ArgumentError,
          "interrupt_on rule for #{inspect(to_string(tool))} must be true, false or a map of rules, " <>
            "got #{inspect(config)}"
  end

  defp rule_value(config, key), do: Map.get(config, key, Map.get(config, Atom.to_string(key)))

  defp normalize_interrupt_mode!(mode) when mode in [:all, "all", :batch, "batch"], do: :all
  defp normalize_interrupt_mode!(mode) when mode in [:first, "first"], do: :first
  defp normalize_interrupt_mode!(mode) when mode in [:per_call, "per_call"], do: :per_call

  defp normalize_interrupt_mode!(mode),
    do: raise(ArgumentError, "interrupt_mode must be :all, :first or :per_call, got #{inspect(mode)}")

  defp tool_map(tools) do
    tools
    |> List.wrap()
    |> Map.new(fn tool -> {Tool.name(tool), tool} end)
  end

  defp decision_type(decision),
    do: decision_atom(Map.get(decision, :type, Map.get(decision, "type")))

  defp decision_atom(value) when value in @decisions, do: value
  defp decision_atom(value) when is_binary(value), do: Enum.find(@decisions, &(Atom.to_string(&1) == value))
  defp decision_atom(_value), do: nil

  defp decision_message(%Decision{message: message}), do: message
  defp decision_message(decision), do: Map.get(decision, :message, Map.get(decision, "message"))

  defp tool_call_name(call), do: Map.get(call, :name)

  defp tool_call_args(call), do: Map.get(call, :args, %{})
end
