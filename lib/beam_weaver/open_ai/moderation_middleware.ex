defmodule BeamWeaver.OpenAI.ModerationMiddleware do
  @moduledoc """
  Agent middleware backed by OpenAI's moderation endpoint.

  This keeps the LangChain moderation behavior while using BeamWeaver's native
  middleware contract: hook functions return updates, jumps, or tagged errors
  instead of raising Python exceptions.
  """

  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.OpenAI.Client

  @default_model "omni-moderation-latest"
  @default_violation_template "I'm sorry, but I can't comply with that request. It was flagged for {categories}."
  @exit_behaviors [:error, :end, :replace]

  defstruct model: @default_model,
            check_input: true,
            check_output: true,
            check_tool_results: false,
            exit_behavior: :end,
            violation_message: nil,
            client: nil

  @type stage :: :input | :output | :tool

  @type t :: %__MODULE__{
          model: String.t(),
          check_input: boolean(),
          check_output: boolean(),
          check_tool_results: boolean(),
          exit_behavior: :error | :end | :replace,
          violation_message: String.t() | nil,
          client: Client.t() | keyword() | nil
        }

  @doc """
  Builds a moderation middleware struct.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      model: Keyword.get(opts, :model, @default_model),
      check_input: Keyword.get(opts, :check_input, true),
      check_output: Keyword.get(opts, :check_output, true),
      check_tool_results: Keyword.get(opts, :check_tool_results, false),
      exit_behavior: opts |> Keyword.get(:exit_behavior, :end) |> normalize_exit_behavior!(),
      violation_message: Keyword.get(opts, :violation_message),
      client: Keyword.get(opts, :client, client_from_opts(opts))
    }
  end

  @doc """
  Returns the default violation message template.
  """
  @spec default_violation_template() :: String.t()
  def default_violation_template, do: @default_violation_template

  @impl true
  def name(_middleware), do: :openai_moderation

  @impl true
  def can_jump_to(_middleware, hook) when hook in [:before_model, :after_model], do: [:end]
  def can_jump_to(_middleware, _hook), do: []

  def before_model(%__MODULE__{check_input: false, check_tool_results: false}, _state, _runtime),
    do: nil

  def before_model(%__MODULE__{} = middleware, state, _runtime) do
    messages = state_messages(state)

    if messages == [] do
      nil
    else
      moderate_inputs(middleware, messages)
    end
  end

  def after_model(%__MODULE__{check_output: false}, _state, _runtime), do: nil

  def after_model(%__MODULE__{} = middleware, state, _runtime) do
    messages = state_messages(state)

    if messages == [] do
      nil
    else
      moderate_output(middleware, messages)
    end
  end

  @doc """
  Task-backed equivalent of Python's async `before_model` hook.
  """
  @spec async_before_model(t(), map(), BeamWeaver.Graph.Runtime.t(), keyword()) :: Async.handle()
  def async_before_model(%__MODULE__{} = middleware, state, runtime, opts \\ []) do
    Async.run(fn -> before_model(middleware, state, runtime) end, opts)
  end

  @doc """
  Task-backed equivalent of Python's async `after_model` hook.
  """
  @spec async_after_model(t(), map(), BeamWeaver.Graph.Runtime.t(), keyword()) :: Async.handle()
  def async_after_model(%__MODULE__{} = middleware, state, runtime, opts \\ []) do
    Async.run(fn -> after_model(middleware, state, runtime) end, opts)
  end

  @doc """
  Calls the OpenAI moderation endpoint for a single text value.
  """
  @spec moderate(t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def moderate(%__MODULE__{} = middleware, text) when is_binary(text) do
    body = %{"model" => middleware.model, "input" => text}

    case Client.post_json(
           middleware.client || Client.new(),
           Client.endpoint("moderations"),
           body
         ) do
      {:ok, %{"results" => [result | _]}} ->
        {:ok, result}

      {:ok, response} ->
        {:error,
         Error.new(
           :invalid_openai_moderation_response,
           "OpenAI moderation response is invalid",
           %{
             response: response
           }
         )}

      {:error, error} ->
        {:error,
         Error.new(:openai_moderation_request_failed, "OpenAI moderation request failed", %{
           reason: inspect(error)
         })}
    end
  end

  defp moderate_inputs(middleware, messages) do
    with {:ok, messages, tool_changed?} <-
           maybe_moderate_tool_messages(middleware, messages, middleware.check_tool_results),
         {:ok, messages, input_changed?} <-
           maybe_moderate_last_role(middleware, messages, :user, :input, middleware.check_input) do
      if tool_changed? or input_changed?, do: %{messages: messages}, else: nil
    else
      {:jump, :end, update} -> {:jump, :end, update}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp moderate_output(middleware, messages) do
    case maybe_moderate_last_role(middleware, messages, :assistant, :output, true) do
      {:ok, ^messages, false} -> nil
      {:ok, updated, true} -> %{messages: updated}
      {:jump, :end, update} -> {:jump, :end, update}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp maybe_moderate_tool_messages(_middleware, messages, false), do: {:ok, messages, false}

  defp maybe_moderate_tool_messages(middleware, messages, true) do
    case last_role_index(messages, :assistant) do
      nil -> {:ok, messages, false}
      index -> moderate_tool_messages_after(middleware, messages, index + 1, false)
    end
  end

  defp moderate_tool_messages_after(_middleware, messages, index, changed?)
       when index >= length(messages),
       do: {:ok, messages, changed?}

  defp moderate_tool_messages_after(middleware, messages, index, changed?) do
    case Enum.at(messages, index) do
      %Message{role: :tool} = message ->
        case moderate_message_at(middleware, messages, index, :tool, message) do
          {:ok, ^messages, false} ->
            moderate_tool_messages_after(middleware, messages, index + 1, changed?)

          {:ok, updated, true} ->
            moderate_tool_messages_after(middleware, updated, index + 1, true)

          other ->
            other
        end

      _other ->
        moderate_tool_messages_after(middleware, messages, index + 1, changed?)
    end
  end

  defp maybe_moderate_last_role(_middleware, messages, _role, _stage, false),
    do: {:ok, messages, false}

  defp maybe_moderate_last_role(middleware, messages, role, stage, true) do
    case last_role_index(messages, role) do
      nil -> {:ok, messages, false}
      index -> moderate_message_at(middleware, messages, index, stage, Enum.at(messages, index))
    end
  end

  defp moderate_message_at(middleware, messages, index, stage, %Message{} = message) do
    text = Message.text(message)

    if text == "" do
      {:ok, messages, false}
    else
      with {:ok, result} <- moderate(middleware, text) do
        if flagged?(result) do
          apply_violation(middleware, messages, index, stage, text, result)
        else
          {:ok, messages, false}
        end
      end
    end
  end

  defp apply_violation(
         %__MODULE__{exit_behavior: :error} = middleware,
         _messages,
         _index,
         stage,
         content,
         result
       ) do
    {:error,
     Error.new(
       :openai_moderation_violation,
       format_violation_message(middleware, content, result),
       %{
         content: content,
         stage: stage,
         result: result
       }
     )}
  end

  defp apply_violation(
         %__MODULE__{exit_behavior: :end} = middleware,
         _messages,
         _index,
         _stage,
         content,
         result
       ) do
    message = Message.assistant(format_violation_message(middleware, content, result))
    {:jump, :end, %{messages: [message]}}
  end

  defp apply_violation(
         %__MODULE__{exit_behavior: :replace} = middleware,
         messages,
         index,
         _stage,
         content,
         result
       ) do
    original = Enum.at(messages, index)
    replacement = %{original | content: format_violation_message(middleware, content, result)}
    {:ok, List.replace_at(messages, index, replacement), true}
  end

  defp format_violation_message(middleware, content, result) do
    template = middleware.violation_message || @default_violation_template

    replacements = %{
      "{categories}" => category_label(result),
      "{category_scores}" => BeamWeaver.JSON.encode!(Map.get(result, "category_scores", %{}), maps: :strict),
      "{original_content}" => content
    }

    Enum.reduce(replacements, template, fn {placeholder, value}, acc ->
      String.replace(acc, placeholder, value)
    end)
  end

  defp category_label(result) do
    categories =
      result
      |> Map.get("categories", %{})
      |> Enum.filter(fn {_name, flagged?} -> flagged? == true end)
      |> Enum.map(fn {name, _flagged?} ->
        name
        |> to_string()
        |> String.replace(~r/[_\/-]+/u, " ")
      end)

    case categories do
      [] -> "OpenAI's safety policies"
      categories -> Enum.join(categories, ", ")
    end
  end

  defp flagged?(%{"flagged" => true}), do: true
  defp flagged?(%{flagged: true}), do: true
  defp flagged?(_result), do: false

  defp last_role_index(messages, role) do
    messages
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn
      {%Message{role: ^role}, index} -> index
      _other -> nil
    end)
  end

  defp state_messages(state) do
    Map.get(state, :messages, []) || []
  end

  defp normalize_exit_behavior!(behavior) when behavior in @exit_behaviors, do: behavior

  defp normalize_exit_behavior!(behavior) when is_binary(behavior) do
    behavior
    |> String.to_existing_atom()
    |> normalize_exit_behavior!()
  rescue
    ArgumentError -> reraise ArgumentError, [message: "invalid OpenAI moderation exit_behavior"], __STACKTRACE__
  end

  defp normalize_exit_behavior!(_behavior),
    do: raise(ArgumentError, "invalid OpenAI moderation exit_behavior")

  defp client_from_opts(opts) do
    opts
    |> Keyword.take([:api_key, :organization, :project, :transport, :transport_opts, :timeout])
    |> Client.new()
  end
end
