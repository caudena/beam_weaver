defmodule BeamWeaver.OutputParser.OpenAI do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages
  alias BeamWeaver.OutputParser.JSON
  alias BeamWeaver.OutputParser.Schema
  alias BeamWeaver.Result

  @spec parse_tools(term(), keyword() | map()) ::
          {:ok, [map()] | map() | nil} | {:error, Error.t()}
  def parse_tools(input, opts \\ []) do
    opts = if is_map(opts), do: opts, else: Map.new(opts)

    input
    |> extract_tool_calls()
    |> case do
      {:ok, calls} ->
        calls
        |> Enum.map(&normalize_tool_call(&1, opts))
        |> Enum.reject(&is_nil/1)
        |> filter_tool_calls(opts)
        |> project_tool_calls(opts)

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  @spec stream_tools(map(), term()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def stream_tools(parser, input) when is_map(parser) do
    if Enumerable.impl_for(input) do
      parser = Map.put(parser, :partial, true)

      stream =
        input
        |> Stream.transform({nil, nil}, fn chunk, {acc, last_key} ->
          acc = Messages.MessageChunk.merge(acc, chunk)

          emitted =
            case parse_tools(acc, parser) do
              {:ok, parsed} ->
                key = :erlang.term_to_binary(parsed)

                if key == last_key do
                  []
                else
                  [parsed]
                end

              {:error, %Error{details: %{parser: :openai_tools_parser}}} ->
                key = :erlang.term_to_binary([])

                if key == last_key do
                  []
                else
                  [[]]
                end

              {:error, _error} ->
                []
            end

          next_key =
            case emitted do
              [] -> last_key
              [value] -> :erlang.term_to_binary(value)
            end

          {emitted, {acc, next_key}}
        end)

      {:ok, stream}
    else
      case parse_tools(input, parser) do
        {:ok, value} -> {:ok, [value]}
        {:error, error} -> {:error, error}
      end
    end
  end

  @spec parse_functions(term(), keyword() | map()) ::
          {:ok, map() | [map()] | nil} | {:error, Error.t()}
  def parse_functions(input, opts \\ []) do
    opts =
      opts
      |> then(fn opts -> if is_map(opts), do: opts, else: Map.new(opts) end)
      |> Map.put_new(:error_on_invalid_args, true)

    with {:ok, calls} <- extract_function_calls(input) do
      calls =
        calls
        |> Enum.map(&normalize_tool_call(&1, opts))
        |> Enum.reject(&is_nil/1)

      if calls == [] and Map.get(opts, :required, true) do
        parser_error(:openai_functions_parser, "input did not contain OpenAI function calls")
      else
        calls
        |> project_function_calls(opts)
        |> project_first_function_call(opts)
      end
    end
  end

  defp extract_tool_calls(%Message{tool_calls: calls}) when is_list(calls), do: {:ok, calls}
  defp extract_tool_calls(%Messages.AIChunk{tool_calls: calls}) when calls != [], do: {:ok, calls}

  defp extract_tool_calls(%Messages.AIChunk{tool_call_chunks: chunks}) when chunks != [],
    do: {:ok, chunks}

  defp extract_tool_calls(%Messages.Chunk{tool_calls: calls}) when calls != [], do: {:ok, calls}

  defp extract_tool_calls(%Messages.Chunk{tool_call_chunks: chunks}) when chunks != [],
    do: {:ok, chunks}

  defp extract_tool_calls(%Messages.AIChunk{}), do: {:ok, []}
  defp extract_tool_calls(%Messages.Chunk{}), do: {:ok, []}
  defp extract_tool_calls(%Message{tool_calls: nil}), do: {:ok, []}

  defp extract_tool_calls(calls) when is_list(calls), do: {:ok, calls}

  defp extract_tool_calls(_input),
    do: parser_error(:openai_tools_parser, "input did not contain OpenAI tool calls")

  defp extract_function_calls(%{"function_call" => call}),
    do: {:ok, [mark_legacy_function_call(call)]}

  defp extract_function_calls(%{function_call: call}),
    do: {:ok, [mark_legacy_function_call(call)]}

  defp extract_function_calls(%Message{role: :assistant, tool_calls: [call | _rest]}),
    do: {:ok, [call]}

  defp extract_function_calls(%Message{role: :assistant}), do: {:ok, []}

  defp extract_function_calls(%Message{}),
    do: parser_error(:openai_functions_parser, "input did not contain OpenAI function calls")

  defp extract_function_calls(input), do: extract_tool_calls(input)

  defp normalize_tool_call(%Messages.ToolCall{} = call, opts) do
    normalize_tool_call(%{id: call.id, name: call.name, args: call.args}, opts)
  end

  defp normalize_tool_call(%Messages.ToolCallChunk{} = call, opts) do
    normalize_tool_call(%{id: call.id, name: call.name, args: call.args, index: call.index}, opts)
  end

  defp normalize_tool_call(call, opts) when is_map(call) do
    function = BeamWeaver.MapAccess.get(call, :function, %{})

    args =
      first_present(call, [:args, "args", :arguments, "arguments"])
      |> case do
        :__beam_weaver_missing__ -> first_present(function, [:arguments, "arguments"])
        value -> value
      end
      |> case do
        :__beam_weaver_missing__ -> %{}
        value -> value
      end

    if Map.get(opts, :partial, false) and is_nil(args) do
      nil
    else
      decoded =
        if Map.get(call, :__legacy_function_call__) == true and not is_binary(args) do
          %Messages.InvalidToolCall{args: inspect(args), error: "arguments must be a JSON string"}
        else
          decode_args(args, Map.get(opts, :partial, false), Map.get(opts, :strict, false))
        end

      base = %{
        id:
          BeamWeaver.MapAccess.get(call, :call_id) ||
            BeamWeaver.MapAccess.get(call, :id),
        name:
          BeamWeaver.MapAccess.get(call, :name) ||
            BeamWeaver.MapAccess.get(function, :name),
        args: decoded
      }

      if Map.get(opts, :return_id, false), do: base, else: Map.delete(base, :id)
    end
  end

  defp first_present(map, keys) do
    Enum.reduce_while(keys, :__beam_weaver_missing__, fn key, :__beam_weaver_missing__ ->
      if Map.has_key?(map, key) do
        {:halt, Map.get(map, key)}
      else
        {:cont, :__beam_weaver_missing__}
      end
    end)
  end

  defp mark_legacy_function_call(call) when is_map(call),
    do: Map.put(call, :__legacy_function_call__, true)

  defp mark_legacy_function_call(call), do: call

  defp decode_args(args, _partial, _strict) when is_map(args), do: args
  defp decode_args("", _partial, _strict), do: %{}

  defp decode_args(args, partial, strict) when is_binary(args) do
    case JSON.parse(args, partial: partial) do
      {:ok, decoded} when is_map(decoded) -> decoded
      {:error, _error} when not strict -> decode_repaired_function_args(args, partial)
      _other -> %Messages.InvalidToolCall{args: args, error: "arguments were not valid JSON"}
    end
  end

  defp decode_args(nil, _partial, _strict), do: %{}
  defp decode_args(_args, _partial, _strict), do: %{}

  defp decode_repaired_function_args(args, partial) do
    args
    |> escape_json_control_chars()
    |> JSON.parse(partial: partial)
    |> case do
      {:ok, decoded} when is_map(decoded) ->
        decoded

      _other ->
        %Messages.InvalidToolCall{args: args, error: "arguments were not valid JSON"}
    end
  end

  defp escape_json_control_chars(text) do
    text
    |> String.to_charlist()
    |> Enum.reduce({[], false, false}, fn char, {acc, in_string?, escaped?} ->
      cond do
        escaped? ->
          {[char | acc], in_string?, false}

        in_string? and char == ?\\ ->
          {[char | acc], in_string?, true}

        char == ?" ->
          {[char | acc], not in_string?, false}

        in_string? and char < 0x20 ->
          {json_control_escape(char) ++ acc, in_string?, false}

        true ->
          {[char | acc], in_string?, false}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> List.to_string()
  end

  defp json_control_escape(?\n), do: ~c"n\\"
  defp json_control_escape(?\r), do: ~c"r\\"
  defp json_control_escape(?\t), do: ~c"t\\"
  defp json_control_escape(?\b), do: ~c"b\\"
  defp json_control_escape(?\f), do: ~c"f\\"

  defp json_control_escape(char) do
    char
    |> Integer.to_string(16)
    |> String.pad_leading(4, "0")
    |> String.to_charlist()
    |> Enum.reverse()
    |> then(&(&1 ++ ~c"u\\"))
  end

  defp filter_tool_calls(calls, opts) do
    case Map.get(opts, :key_name) do
      nil -> calls
      key -> Enum.filter(calls, &(Map.get(&1, :name) == key))
    end
  end

  defp project_tool_calls(calls, opts) do
    calls =
      if Map.get(opts, :key_name) && Map.get(opts, :return_id) == false do
        Enum.map(calls, & &1.args)
      else
        calls
      end

    calls =
      if Map.get(opts, :first_only, false) do
        case calls do
          [] -> nil
          [first | _rest] -> first
        end
      else
        calls
      end

    {:ok, calls}
  end

  defp project_function_calls(calls, opts) do
    Result.traverse(calls, &project_function_call(&1, opts))
  end

  defp project_function_call(%{args: %Messages.InvalidToolCall{} = invalid}, opts) do
    if Map.get(opts, :error_on_invalid_args, false) do
      parser_error(:openai_functions_parser, "function arguments were not valid JSON", %{
        arguments: invalid.args,
        reason: invalid.error
      })
    else
      {:ok, invalid}
    end
  end

  defp project_function_call(call, opts) do
    with {:ok, call} <- maybe_cast_function_call(call, opts) do
      cond do
        key_name = Map.get(opts, :key_name) ->
          project_function_key(call, key_name, opts)

        Map.get(opts, :args_only, false) ->
          {:ok, call.args}

        true ->
          {:ok, call}
      end
    end
  end

  defp maybe_cast_function_call(%{args: args} = call, opts) when is_map(args) do
    schema = function_schema(call.name, opts)
    as = function_cast(call.name, opts)

    with :ok <- maybe_validate_function_schema(schema, args),
         {:ok, casted} <- Schema.cast(args, as) do
      {:ok, %{call | args: casted}}
    end
  end

  defp maybe_cast_function_call(call, _opts), do: {:ok, call}

  defp maybe_validate_function_schema(nil, _args), do: :ok

  defp maybe_validate_function_schema(schema, args) do
    schema
    |> Schema.normalize_module_schema()
    |> case do
      nil -> :ok
      schema -> Schema.validate(schema, args)
    end
  end

  defp function_schema(name, opts) do
    cond do
      schemas = Map.get(opts, :schemas) ->
        named_value(schemas, name)

      schema = Map.get(opts, :schema) ->
        schema

      as = function_cast(name, opts) ->
        Schema.normalize_module_schema(as)

      true ->
        nil
    end
  end

  defp function_cast(name, opts) do
    case Map.get(opts, :as) do
      nil -> nil
      values when is_map(values) -> named_value(values, name)
      value -> value
    end
  end

  defp named_value(values, name) when is_map(values) do
    name = to_string(name)

    Enum.find_value(values, fn {key, value} ->
      if to_string(key) == name, do: value, else: nil
    end)
  end

  defp named_value(_values, _name), do: nil

  defp project_function_key(%{args: %Messages.InvalidToolCall{} = invalid}, _key_name, _opts),
    do: {:ok, invalid}

  defp project_function_key(%{args: args}, key_name, opts) when is_map(args) do
    case Schema.fetch_key(args, key_name) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        if Map.get(opts, :partial, false) do
          {:ok, nil}
        else
          parser_error(:openai_functions_parser, "function arguments missing requested key", %{
            key: key_name
          })
        end
    end
  end

  defp project_function_key(call, _key_name, _opts), do: {:ok, call.args}

  defp project_first_function_call({:error, %Error{} = error}, _opts), do: {:error, error}

  defp project_first_function_call({:ok, calls}, opts) do
    if Map.get(opts, :first_only, true) do
      {:ok, List.first(calls)}
    else
      {:ok, calls}
    end
  end

  defp parser_error(parser, message, details \\ %{}) do
    {:error, Error.new(:output_parser_error, message, Map.put(details, :parser, parser))}
  end
end
