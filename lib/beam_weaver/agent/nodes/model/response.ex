defmodule BeamWeaver.Agent.Nodes.Model.Response do
  @moduledoc false

  alias BeamWeaver.Agent.ExtendedModelResponse
  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Agent.ModelResponse
  alias BeamWeaver.Agent.ToolSet
  alias BeamWeaver.Agent.Usage
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Overwrite
  alias BeamWeaver.Transport.Redactor

  def normalize_model_result({:ok, %ModelResponse{}} = result), do: result

  def normalize_model_result({:ok, %ExtendedModelResponse{} = response}),
    do: normalize_model_result(response)

  def normalize_model_result({:error, %Error{} = error}), do: {:error, sanitize_error(error)}
  def normalize_model_result({:error, reason}), do: {:error, normalize_error(reason)}
  def normalize_model_result(%ModelResponse{} = response), do: {:ok, response}

  def normalize_model_result(%ExtendedModelResponse{
        model_response: %ModelResponse{} = response,
        command: nil
      }),
      do: {:ok, response}

  def normalize_model_result(%ExtendedModelResponse{
        model_response: %ModelResponse{} = response,
        command: %Command{} = command
      }) do
    {:ok, append_response_command(response, command)}
  end

  def normalize_model_result(%Message{} = message),
    do: {:ok, %ModelResponse{messages: [message]}}

  def normalize_model_result(other) do
    {:error,
     Error.new(:invalid_model_response, "model middleware returned an invalid response", %{
       returned: inspect(other)
     })}
  end

  def attach_diagnostics(%Error{} = error, request, messages, opts, response \\ nil) do
    details =
      error.details
      |> safe_details()
      |> Map.put_new(:model_request, model_request_details(request, messages, opts))
      |> maybe_put_model_response(response)
      |> safe_details()

    %{error | details: details}
  end

  defp normalize_error(%{type: type, message: message} = error)
       when is_atom(type) and is_binary(message) do
    Error.new(type, message, error_details(error))
  end

  defp normalize_error(%{__exception__: true} = exception) do
    Error.new(:model_error, Exception.message(exception), %{reason: inspect(exception)})
  end

  defp normalize_error(message) when is_binary(message), do: Error.new(:model_error, message)

  defp normalize_error(reason) do
    Error.new(:model_error, "model returned an error", %{reason: inspect(reason)})
  end

  defp error_details(error) do
    details =
      case Map.get(error, :details) do
        details when is_map(details) -> details
        _other -> %{}
      end

    details
    |> safe_details()
    |> Map.put_new(:reason, inspect(error))
  end

  defp model_request_details(request, messages, opts) do
    %{
      model: model_name(request.model),
      messages: Enum.map(messages, &message_details/1),
      response_format: response_format_details(request.response_format),
      tools: Enum.map(ToolSet.list(request.tool_set || ToolSet.new(request.tools)), &Tool.name/1),
      opts: redact_and_clip(opts)
    }
  end

  defp maybe_put_model_response(details, nil), do: details

  defp maybe_put_model_response(details, %Message{} = response) do
    Map.put_new(details, :model_response, message_details(response))
  end

  defp maybe_put_model_response(details, response) do
    Map.put_new(details, :model_response, redact_and_clip(response))
  end

  defp model_name(%{model: model}) when is_binary(model), do: model

  defp model_name(model) do
    module = if is_map(model), do: Map.get(model, :__struct__), else: nil

    cond do
      is_atom(module) and function_exported?(module, :model_name, 1) ->
        module.model_name(model)

      is_atom(module) and function_exported?(module, :model_id, 1) ->
        module.model_id(model)

      is_atom(module) ->
        inspect(module)

      true ->
        inspect(model)
    end
  end

  defp message_details(%Message{} = message) do
    %{
      role: message.role,
      name: message.name,
      content: redact_and_clip(Message.text(message)),
      metadata: redact_and_clip(message.metadata),
      response_metadata: redact_and_clip(message.response_metadata),
      tool_calls: redact_and_clip(message.tool_calls)
    }
  end

  defp response_format_details(nil), do: nil

  defp response_format_details(%{schema_spec: spec, strict: strict}) do
    %{
      strategy: :provider,
      name: Map.get(spec, :name),
      schema: redact_and_clip(Map.get(spec, :json_schema)),
      strict: strict
    }
  end

  defp response_format_details(%{schema_specs: specs}) when is_list(specs) do
    %{
      strategy: :tool,
      schemas:
        Enum.map(specs, fn spec ->
          %{
            name: Map.get(spec, :name),
            schema: redact_and_clip(Map.get(spec, :json_schema))
          }
        end)
    }
  end

  defp response_format_details(response_format), do: redact_and_clip(response_format)

  defp redact_and_clip(value), do: value |> Redactor.redact() |> clip_value()

  defp clip_value(value) when is_binary(value) do
    max = 8_000

    if byte_size(value) > max do
      clip_to_valid(value, max) <> "\n...[truncated #{byte_size(value) - max} bytes]"
    else
      value
    end
  end

  defp clip_value(values) when is_list(values), do: Enum.map(values, &clip_value/1)

  defp clip_value(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&clip_value/1)
    |> List.to_tuple()
  end

  defp clip_value(value) when is_map(value) do
    Map.new(value, fn {key, map_value} -> {key, clip_value(map_value)} end)
  end

  defp clip_value(value), do: value

  defp clip_to_valid(value, max) do
    candidate = binary_part(value, 0, max)

    if String.valid?(candidate) do
      candidate
    else
      Enum.reduce_while(1..3, candidate, fn n, acc ->
        shrunk = binary_part(value, 0, max - n)
        if String.valid?(shrunk), do: {:halt, shrunk}, else: {:cont, acc}
      end)
    end
  end

  defp sanitize_error(%Error{details: details} = error), do: %{error | details: safe_details(details)}

  defp safe_details(details) when is_map(details) do
    Map.new(details, fn {key, value} -> {safe_detail_key(key), safe_detail_value(value)} end)
  end

  defp safe_details(_details), do: %{}

  defp safe_detail_key(key) when is_atom(key) or is_binary(key), do: key
  defp safe_detail_key(key), do: inspect(key)

  defp safe_detail_value(%Error{} = error), do: sanitize_error(error)

  defp safe_detail_value(%{__struct__: _module} = value) do
    if serializable?(value), do: value, else: inspect(value)
  end

  defp safe_detail_value(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {safe_detail_key(key), safe_detail_value(nested)} end)
  end

  defp safe_detail_value(values) when is_list(values), do: Enum.map(values, &safe_detail_value/1)

  defp safe_detail_value(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&safe_detail_value/1)
    |> List.to_tuple()
  end

  defp safe_detail_value(value) do
    if serializable?(value), do: value, else: inspect(value)
  end

  defp serializable?(value) do
    match?({:ok, _encoded}, BeamWeaver.Serialization.dump_value(value))
  end

  def to_update(%ModelResponse{commands: commands} = response, opts) when commands != [] do
    base_update = base_response_update(response, opts)

    case Enum.split_with(commands, &message_overwrite_command?/1) do
      {[], commands} ->
        [base_update | commands]

      {overwrites, commands} ->
        Enum.map(overwrites, &append_messages_to_overwrite(&1, response.messages)) ++
          [Map.delete(base_update, :messages) | commands]
    end
  end

  def to_update(%ModelResponse{} = response, opts), do: base_response_update(response, opts)

  def attach_runtime_metadata(%ModelResponse{} = response, %ToolSet{} = tool_set) do
    %{response | tool_set: tool_set, usage: Usage.from_messages(response.messages)}
  end

  def put_assistant_name(%ModelResponse{} = response, %ModelRequest{model_opts: opts}) do
    case Keyword.get(opts, :assistant_name) do
      nil ->
        response

      name ->
        %{response | messages: Enum.map(response.messages, &put_assistant_name_to_message(&1, name))}
    end
  end

  # Without the steps for its tool calls, a run would stop with a recursion
  # limit error halfway through a tool round. The model's reply becomes an
  # answer that says so instead, while the run can still finish.
  @default_step_costs %{tool_round: 2, return_direct: 1}

  def maybe_limit_steps_response(
        %ModelRequest{} = request,
        %ModelResponse{messages: [%Message{} = message | rest]} = response,
        step_costs
      ) do
    if more_steps_needed?(request, message, rest, step_costs || @default_step_costs) do
      %ModelResponse{messages: [step_limit_message(message)]}
    else
      response
    end
  end

  def maybe_limit_steps_response(_request, response, _step_costs), do: response

  # A `:history` the model node repaired replaces the thread's messages, with
  # the reply after it.
  defp base_response_update(%ModelResponse{} = response, opts) do
    messages =
      case Keyword.get(opts, :history) do
        nil -> response.messages
        history -> Overwrite.new(history ++ response.messages)
      end

    %{messages: messages}
    |> put_structured_response(response.structured_response, Keyword.get(opts, :structured_output, false))
    |> maybe_put_tool_set(response.tool_set)
    |> maybe_put_usage(response.usage)
  end

  # An agent with a response format clears an earlier turn's answer when this
  # call made none, so a checkpointed thread can't end on the old one.
  defp put_structured_response(update, nil, true), do: Map.put(update, :structured_response, nil)
  defp put_structured_response(update, nil, false), do: update
  defp put_structured_response(update, value, _structured_output), do: Map.put(update, :structured_response, value)

  defp maybe_put_tool_set(update, nil), do: update

  defp maybe_put_tool_set(update, %ToolSet{} = tool_set),
    do: Map.merge(update, %{tool_set: tool_set, tool_set_names: ToolSet.names(tool_set)})

  defp maybe_put_usage(update, nil), do: update
  defp maybe_put_usage(update, %Usage{} = usage), do: Map.put(update, :usage, usage)

  defp append_response_command(%ModelResponse{} = response, %Command{} = command) do
    %{
      response
      | commands: response.commands ++ [%{command | update: normalize_command_update(command.update)}]
    }
  end

  defp message_overwrite_command?(%Command{update: update}) when is_map(update) do
    case fetch_update_value(update, :messages) do
      {:ok, _key, value} -> match?({:ok, _value}, Overwrite.get(value))
      :error -> false
    end
  end

  defp message_overwrite_command?(_command), do: false

  defp append_messages_to_overwrite(command, []), do: command

  defp append_messages_to_overwrite(%Command{update: update} = command, messages) do
    {:ok, key, value} = fetch_update_value(update, :messages)
    {:ok, overwritten} = Overwrite.get(value)
    %{command | update: Map.put(update, key, Overwrite.new(List.wrap(overwritten) ++ messages))}
  end

  defp fetch_update_value(update, key) do
    case Map.fetch(update, key) do
      {:ok, value} -> {:ok, key, value}
      :error -> fetch_string_update_value(update, key)
    end
  end

  defp fetch_string_update_value(update, key) do
    string_key = to_string(key)

    case Map.fetch(update, string_key) do
      {:ok, value} -> {:ok, string_key, value}
      :error -> :error
    end
  end

  defp put_assistant_name_to_message(%Message{role: :assistant, name: nil} = message, name),
    do: %{message | name: to_string(name)}

  defp put_assistant_name_to_message(message, _name), do: message

  # `remaining_steps` counts the model's own step. The tool calls that the
  # response doesn't answer itself (as the structured-output tool strategy
  # does) need `step_costs.tool_round` more steps, or `step_costs.return_direct`
  # when every called tool ends the run.
  defp more_steps_needed?(
         %ModelRequest{state: state, runtime: runtime, tools: tools, tool_set: tool_set},
         %Message{role: :assistant, tool_calls: tool_calls},
         answers,
         step_costs
       ) do
    remaining_steps = Map.get(state, :remaining_steps) || Map.get(runtime || %{}, :recursion_limit)

    pending_calls = pending_tool_calls(tool_calls || [], answers)

    if is_integer(remaining_steps) and pending_calls != [] do
      tools = if tool_set, do: ToolSet.list(tool_set), else: tools

      needed =
        if Enum.all?(pending_calls, &return_direct_tool?(&1, tools)),
          do: step_costs.return_direct,
          else: step_costs.tool_round

      remaining_steps <= needed
    else
      false
    end
  end

  defp more_steps_needed?(_request, _message, _answers, _step_costs), do: false

  defp pending_tool_calls(tool_calls, answers) do
    answered =
      for %Message{role: :tool, tool_call_id: id} <- answers, not is_nil(id), into: MapSet.new(), do: id

    Enum.reject(tool_calls, &MapSet.member?(answered, tool_call_id(&1)))
  end

  def tool_call_id(call),
    do: Map.get(call, :call_id) || Map.get(call, :tool_call_id) || Map.get(call, :id) || Map.get(call, :provider_id)

  defp step_limit_message(%Message{} = response) do
    Message.assistant("Sorry, need more steps to process this request.", id: response.id)
  end

  defp return_direct_tool?(call, tools) do
    name = Map.get(call, :name)

    Enum.any?(tools, fn tool ->
      Tool.name(tool) == name and Tool.return_direct(tool)
    end)
  end

  defp normalize_command_update(update) when is_map(update), do: update
  defp normalize_command_update(_update), do: %{}
end
