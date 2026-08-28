defmodule BeamWeaver.Provider.Replay do
  @moduledoc """
  Bounded provider-native assistant replay projection.

  Only request-critical blocks and correlation fields are retained. Raw HTTP
  responses, usage, traces, tool-result bodies, and arbitrary metadata are
  deliberately excluded.
  """

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Error

  @version 1
  @maximum_bytes 8 * 1024 * 1024

  @spec project(Message.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def project(%Message{role: :assistant} = message, binding) when is_map(binding) do
    with {:ok, tool_calls} <- replay_tool_calls(message.tool_calls) do
      projection = %{
        "version" => @version,
        "binding" => stringify(binding),
        "status" => scalar(message.status),
        "content" => replay_blocks(message, binding),
        "tool_calls" => tool_calls
      }

      encode_projection(projection)
    end
  end

  def project(%Message{}, _binding),
    do: {:error, Error.new(:invalid_provider_replay, "only assistant messages can be replayed")}

  defp encode_projection(projection) do
    with {:ok, encoded} <- BeamWeaver.JSON.encode(projection),
         true <- byte_size(encoded) <= @maximum_bytes do
      {:ok, projection}
    else
      false -> {:error, Error.new(:provider_replay_too_large, "provider replay exceeds the safe limit")}
      {:error, _reason} -> {:error, Error.new(:invalid_provider_replay, "provider replay is not JSON encodable")}
    end
  end

  @spec restore(map(), map()) :: {:ok, Message.t()} | {:error, Error.t()}
  def restore(%{"version" => @version, "binding" => binding} = projection, expected_binding)
      when is_map(expected_binding) do
    with {:ok, _bounded_projection} <- encode_projection(projection),
         true <- binding_matches?(projection, expected_binding),
         {:ok, content} <- restore_blocks(projection["content"] || [], binding["provider"]),
         {:ok, tool_calls} <- restore_tool_calls(projection["tool_calls"] || []),
         {:ok, message} <-
           Message.new(:assistant, content,
             status: projection["status"],
             tool_calls: tool_calls
           ),
         :ok <- Message.validate(message) do
      {:ok, message}
    else
      false ->
        {:error, Error.new(:provider_replay_binding_mismatch, "provider replay binding does not match the request")}

      {:error, _error} = error ->
        error
    end
  end

  def restore(_projection, _expected_binding),
    do: {:error, Error.new(:invalid_provider_replay, "provider replay projection is invalid")}

  @doc """
  Returns whether a replay projection belongs to the exact expected provider binding.

  This check is pure and does not materialize or validate replay content, so callers
  can discard foreign replay rows before applying aggregate content limits.
  """
  @spec binding_matches?(term(), term()) :: boolean()
  def binding_matches?(%{"version" => @version, "binding" => binding}, expected_binding)
      when is_map(binding) and is_map(expected_binding),
      do: binding == stringify(expected_binding)

  def binding_matches?(_projection, _expected_binding), do: false

  defp replay_blocks(%Message{} = message, binding) do
    case Message.content_blocks(message) do
      {:ok, blocks} ->
        Enum.flat_map(blocks, fn block ->
          case replay_boundary_block(block, binding) do
            nil -> replay_block(block)
            projected -> projected
          end
        end)

      _error ->
        []
    end
  end

  defp replay_boundary_block(
         %ContentBlock.Unknown{provider_type: type, value: value},
         binding
       )
       when type in [:fallback, "fallback"] and is_map(value) do
    if provider_binding?(binding, :anthropic) do
      raw = Map.get(value, :raw_provider_block) || Map.get(value, "raw_provider_block") || value

      case stringify(raw) do
        %{"type" => "fallback"} = provider_block ->
          [%{"type" => "anthropic_fallback", "provider_block" => provider_block}]

        _invalid ->
          []
      end
    end
  end

  defp replay_boundary_block(_block, _binding), do: nil

  defp replay_block(%ContentBlock.Text{text: text, metadata: metadata}),
    do: [%{"type" => "text", "text" => text, "provider" => provider_fields(metadata)}]

  defp replay_block(%ContentBlock.PlainText{text: text, metadata: metadata}),
    do: [%{"type" => "plain_text", "text" => text, "provider" => provider_fields(metadata)}]

  defp replay_block(%ContentBlock.Reasoning{reasoning: reasoning, metadata: metadata}),
    do: [%{"type" => "reasoning", "reasoning" => reasoning, "provider" => provider_fields(metadata)}]

  defp replay_block(%{} = block) do
    case Map.get(block, :type) || Map.get(block, "type") do
      type when type in [:text, "text", :plain_text, "plain_text"] ->
        [
          %{
            "type" => to_string(type),
            "text" => Map.get(block, :text) || Map.get(block, "text") || "",
            "provider" => provider_fields(block)
          }
        ]

      type when type in [:reasoning, "reasoning"] ->
        [
          %{
            "type" => "reasoning",
            "reasoning" => Map.get(block, :reasoning) || Map.get(block, "reasoning") || "",
            "provider" => provider_fields(block)
          }
        ]

      type when type in [:refusal, "refusal"] ->
        [%{"type" => "refusal", "refusal" => Map.get(block, :refusal) || Map.get(block, "refusal") || ""}]

      _other ->
        []
    end
  end

  defp replay_block(_block), do: []

  defp provider_fields(metadata) when is_map(metadata) do
    raw = Map.get(metadata, :raw_provider_block) || Map.get(metadata, "raw_provider_block") || metadata

    ~w(type id status signature thoughtSignature thought_signature encrypted_content summary)
    |> Enum.reduce(%{}, fn key, acc ->
      case Map.get(raw, key) || Map.get(raw, safe_existing_atom(key)) do
        nil -> acc
        value when is_binary(value) or is_number(value) or is_boolean(value) -> Map.put(acc, key, value)
        value when key == "summary" and is_list(value) -> Map.put(acc, key, stringify(value))
        _value -> acc
      end
    end)
  end

  defp provider_fields(_metadata), do: %{}

  defp replay_tool_calls(calls) when is_list(calls) do
    Enum.reduce_while(calls, {:ok, []}, fn call, {:ok, projected} ->
      case replay_tool_call(call) do
        {:ok, value} -> {:cont, {:ok, [value | projected]}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, projected} -> {:ok, Enum.reverse(projected)}
      {:error, _error} = error -> error
    end
  end

  defp replay_tool_calls(_calls), do: invalid_replay("provider replay tool calls must be a list")

  defp replay_tool_call(call) when is_map(call) do
    id = scalar(Map.get(call, :id) || Map.get(call, "id"))
    provider_id = scalar(Map.get(call, :provider_id) || Map.get(call, "provider_id"))
    call_id = scalar(Map.get(call, :call_id) || Map.get(call, "call_id"))
    name = scalar(Map.get(call, :name) || Map.get(call, "name"))

    arguments =
      Map.get(call, :arguments) || Map.get(call, "arguments") || Map.get(call, :args) ||
        Map.get(call, "args") || %{}

    if is_binary(name) and name != "" and is_map(arguments) and
         Enum.any?([id, provider_id, call_id], &(is_binary(&1) and &1 != "")) do
      {:ok,
       %{
         "id" => id,
         "provider_id" => provider_id,
         "call_id" => call_id,
         "name" => name,
         "arguments" => stringify(arguments),
         "thought_signature" => scalar(Map.get(call, :thought_signature) || Map.get(call, "thought_signature"))
       }
       |> reject_nil()}
    else
      invalid_replay("provider replay tool call is invalid")
    end
  end

  defp replay_tool_call(_call), do: invalid_replay("provider replay tool call is invalid")

  defp restore_blocks(blocks, binding_provider) when is_list(blocks) do
    Enum.reduce_while(blocks, {:ok, []}, fn block, {:ok, restored} ->
      case restore_block(block, binding_provider) do
        {:ok, value} -> {:cont, {:ok, [value | restored]}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, restored} -> {:ok, Enum.reverse(restored)}
      {:error, _error} = error -> error
    end
  end

  defp restore_blocks(_blocks, _provider),
    do: invalid_replay("provider replay content must be a list")

  defp restore_block(
         %{
           "type" => "anthropic_fallback",
           "provider_block" => %{"type" => "fallback"} = provider_block
         },
         "anthropic"
       ) do
    {:ok,
     ContentBlock.unknown("fallback", %{
       type: "fallback",
       raw_provider_block: provider_block
     })}
  end

  defp restore_block(%{"type" => "reasoning", "reasoning" => reasoning} = block, "openai")
       when is_binary(reasoning) do
    with {:ok, provider_fields} <- restore_provider_fields(block) do
      {:ok,
       provider_fields
       |> atomize_provider_fields()
       |> Map.merge(%{type: :reasoning, reasoning: reasoning})}
    end
  end

  defp restore_block(%{"type" => "text", "text" => text} = block, _provider)
       when is_binary(text) do
    with {:ok, provider_fields} <- restore_provider_fields(block),
         do: {:ok, ContentBlock.text(text, provider_fields)}
  end

  defp restore_block(%{"type" => "plain_text", "text" => text} = block, _provider)
       when is_binary(text) do
    with {:ok, provider_fields} <- restore_provider_fields(block),
         do: {:ok, ContentBlock.plain_text(text, provider_fields)}
  end

  defp restore_block(%{"type" => "reasoning", "reasoning" => reasoning} = block, _provider)
       when is_binary(reasoning) do
    with {:ok, provider_fields} <- restore_provider_fields(block),
         do: {:ok, ContentBlock.reasoning(reasoning, provider_fields)}
  end

  defp restore_block(%{"type" => "refusal", "refusal" => refusal}, _provider)
       when is_binary(refusal),
       do: {:ok, %{type: :refusal, refusal: refusal}}

  defp restore_block(_block, _provider), do: invalid_replay("provider replay content block is invalid")

  defp restore_provider_fields(block) do
    case Map.get(block, "provider", %{}) do
      provider_fields when is_map(provider_fields) -> {:ok, provider_fields}
      _invalid -> invalid_replay("provider replay provider fields must be a map")
    end
  end

  defp restore_tool_calls(calls) when is_list(calls) do
    Enum.reduce_while(calls, {:ok, []}, fn call, {:ok, restored} ->
      case restore_tool_call(call) do
        {:ok, value} -> {:cont, {:ok, [value | restored]}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, restored} -> {:ok, Enum.reverse(restored)}
      {:error, _error} = error -> error
    end
  end

  defp restore_tool_calls(_calls), do: invalid_replay("provider replay tool calls must be a list")

  defp restore_tool_call(%{"name" => name, "arguments" => arguments} = call)
       when is_binary(name) and name != "" and is_map(arguments) do
    if Enum.any?([call["id"], call["provider_id"], call["call_id"]], &(is_binary(&1) and &1 != "")) do
      {:ok, atomize_tool_call(call)}
    else
      invalid_replay("provider replay tool call has no correlation id")
    end
  end

  defp restore_tool_call(_call), do: invalid_replay("provider replay tool call is invalid")

  defp atomize_tool_call(call) when is_map(call) do
    %{
      id: call["id"],
      provider_id: call["provider_id"],
      call_id: call["call_id"],
      name: call["name"],
      args: call["arguments"] || %{},
      thought_signature: call["thought_signature"]
    }
    |> reject_nil()
  end

  defp stringify(nil), do: nil

  defp stringify(%{__struct__: _module}), do: nil

  defp stringify(value) when is_map(value) do
    value |> Enum.map(fn {key, item} -> {to_string(key), stringify(item)} end) |> Map.new()
  end

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp stringify(_value), do: nil

  defp scalar(nil), do: nil
  defp scalar(value) when is_atom(value), do: Atom.to_string(value)
  defp scalar(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp scalar(_value), do: nil

  defp reject_nil(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp atomize_provider_fields(fields) do
    Map.new(fields, fn {key, value} -> {provider_field_atom(key), value} end)
  end

  defp provider_field_atom("type"), do: :type
  defp provider_field_atom("id"), do: :id
  defp provider_field_atom("status"), do: :status
  defp provider_field_atom("signature"), do: :signature
  defp provider_field_atom("thoughtSignature"), do: :thought_signature
  defp provider_field_atom("thought_signature"), do: :thought_signature
  defp provider_field_atom("encrypted_content"), do: :encrypted_content
  defp provider_field_atom("summary"), do: :summary

  defp safe_existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> :__missing_replay_key__
  end

  defp provider_binding?(binding, provider) do
    value = Map.get(binding, :provider) || Map.get(binding, "provider")
    value in [provider, Atom.to_string(provider)]
  end

  defp invalid_replay(message),
    do: {:error, Error.new(:invalid_provider_replay, message)}
end
