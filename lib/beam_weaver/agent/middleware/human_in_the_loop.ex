defmodule BeamWeaver.Agent.Middleware.HumanInTheLoop do
  @moduledoc """
  Human review middleware for agent tool calls.

  After the model emits tool calls, reviewable calls are batched into a single
  graph interrupt. On resume, decisions approve, edit, reject, or respond to
  each interrupted call while preserving the original tool-call IDs.

  `interrupt_on` maps tool names to `true`, `false`, or a map of rules. A rule
  map always turns review on: it allows all four decisions unless
  `allowed_decisions` lists fewer. Edited arguments must match the rule's
  `args_schema`, when it has one, and the tool's own input schema.
  """

  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.State
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Graph

  @decisions [:approve, :edit, :reject, :respond]

  defmodule ActionRequest do
    @moduledoc false
    defstruct [:name, args: %{}, description: nil]
  end

  defmodule ReviewConfig do
    @moduledoc false
    defstruct [:action_name, allowed_decisions: [], args_schema: nil]
  end

  defmodule Decision do
    @moduledoc "Typed HITL resume decision."
    defstruct [:type, :message, :edited_action]
  end

  defmodule ValidationError do
    @moduledoc false
    defstruct [:message, details: %{}]
  end

  defstruct interrupt_on: %{},
            interrupt_mode: :all,
            description_prefix: "Tool execution requires approval",
            tools: %{}

  @type t :: %__MODULE__{
          interrupt_on: map(),
          interrupt_mode: :all | :first,
          description_prefix: String.t(),
          tools: map()
        }

  @doc """
  Builds the middleware. Agents build it from their `interrupt_on`
  declaration.

    * `:interrupt_on` - tool names mapped to `true`, `false` or a map of
      rules with `allowed_decisions`, `when`, `description` and `args_schema`.
    * `:interrupt_mode` - `:all` (the default) puts every matching call of a
      model turn in one review; `:first` reviews only the first one.
    * `:description_prefix` - the first line of the default description.

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
  def after_model(%__MODULE__{} = middleware, state, runtime) do
    with {:ok, messages} <- state_messages(state) do
      case last_ai_message(messages) do
        nil ->
          nil

        %Message{tool_calls: calls} = ai_message when is_list(calls) and calls != [] ->
          review = review_requests(middleware, calls, state, runtime)

          if review.action_requests == [] do
            nil
          else
            process_review(middleware, ai_message, calls, review)
          end

        _message ->
          nil
      end
    end
  end

  def after_model(_middleware, _state, _runtime),
    do: {:error, Error.new(:invalid_agent_state, "HITL middleware expected map state")}

  defp process_review(middleware, ai_message, calls, review) do
    request = %{
      action_requests: review.action_requests,
      review_configs: review.review_configs
    }

    request
    |> Graph.interrupt()
    |> decisions()
    |> case do
      {:ok, decisions} ->
        apply_decisions(middleware, ai_message, calls, review.interrupt_indices, decisions)

      {:error, %Error{} = error} ->
        {:error, error}
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
      %{
        action_name: name,
        allowed_decisions: Enum.map(Map.fetch!(config, :allowed_decisions), &Atom.to_string/1)
      }
      |> maybe_put_args_schema(Map.get(config, :args_schema))

    {action_request, review_config}
  end

  defp maybe_put_args_schema(config, nil), do: config
  defp maybe_put_args_schema(config, schema), do: Map.put(config, :args_schema, schema)

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
    |> Enum.reduce_while({:ok, [], []}, fn {call, idx}, {:ok, revised, synthetic} ->
      case Map.fetch(decision_by_index, idx) do
        :error ->
          {:cont, {:ok, revised ++ [call], synthetic}}

        {:ok, {config, decision}} ->
          case process_decision(middleware, decision, call, config) do
            {:ok, revised_call, nil} ->
              {:cont, {:ok, revised ++ [revised_call], synthetic}}

            {:ok, revised_call, %Message{} = message} ->
              {:cont, {:ok, revised ++ [revised_call], synthetic ++ [message]}}

            {:error, %Error{} = error} ->
              {:halt, {:error, error}}
          end
      end
    end)
    |> case do
      {:ok, revised_calls, synthetic_messages} ->
        %{messages: [%{ai_message | tool_calls: revised_calls} | synthetic_messages]}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp process_decision(middleware, decision, call, config) do
    type = decision_type(decision)
    allowed = Map.fetch!(config, :allowed_decisions)

    cond do
      type not in allowed ->
        invalid_decision(decision, call, allowed)

      type == :approve ->
        {:ok, call, nil}

      type == :edit ->
        edit_decision(middleware, decision, call, config)

      type == :reject ->
        {:ok, call, reject_message(decision, call)}

      type == :respond ->
        case decision_message(decision) do
          nil -> invalid_decision(decision, call, allowed)
          message -> {:ok, call, respond_message(message, call)}
        end
    end
  end

  defp edit_decision(middleware, decision, call, config) do
    with {:ok, edited_action} <- edited_action(decision),
         {:ok, edited_call} <- edited_call(call, edited_action),
         :ok <- validate_edited_args(middleware, edited_call, config) do
      {:ok, edited_call, nil}
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
      {:ok, %{id: tool_call_id(call), name: name, args: args}}
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
      decision_message(decision) ||
        "User rejected the tool call for `#{tool_call_name(call)}` with id #{tool_call_id(call)}"

    Message.tool(content,
      name: tool_call_name(call),
      tool_call_id: tool_call_id(call),
      status: "error",
      metadata: %{status: "error"}
    )
  end

  defp respond_message(content, call) do
    Message.tool(content,
      name: tool_call_name(call),
      tool_call_id: tool_call_id(call),
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

  defp last_ai_message(messages) do
    Enum.find(Enum.reverse(messages), &match?(%Message{role: :assistant}, &1))
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

  defp normalize_interrupt_mode!(mode),
    do: raise(ArgumentError, "interrupt_mode must be :all or :first, got #{inspect(mode)}")

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

  defp tool_call_id(call),
    do: Map.get(call, :id) || Map.get(call, :tool_call_id)

  defp tool_call_args(call), do: Map.get(call, :args, %{})
end
