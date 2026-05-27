defmodule BeamWeaver.Runnable.MessageHistory do
  @moduledoc false

  @behaviour BeamWeaver.Runnable

  alias BeamWeaver.Core.ChatHistory
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Runnable
  alias BeamWeaver.Runnable.ConfigField
  alias BeamWeaver.Runnable.ConfigSpec

  defstruct [:runnable, opts: []]

  @impl true
  def invoke(%__MODULE__{} = wrapper, input, opts) do
    with {:ok, session} <- session(wrapper, opts),
         {:ok, history} <- ChatHistory.get_messages(session),
         {:ok, prepared, input_messages} <- prepare_input(input, history, wrapper.opts),
         {:ok, output} <- Runnable.invoke(wrapper.runnable, prepared, opts),
         {:ok, output_messages} <- output_messages(output, wrapper.opts),
         :ok <- ChatHistory.add_messages(session, input_messages ++ output_messages) do
      {:ok, output}
    end
  end

  @impl true
  def stream(%__MODULE__{} = wrapper, input, opts) do
    with {:ok, session} <- session(wrapper, opts),
         {:ok, history} <- ChatHistory.get_messages(session),
         {:ok, prepared, input_messages} <- prepare_input(input, history, wrapper.opts),
         {:ok, stream} <- Runnable.stream(wrapper.runnable, prepared, opts) do
      {:ok, append_after_stream(stream, session, input_messages, wrapper.opts)}
    end
  end

  def config_specs(%__MODULE__{runnable: runnable, opts: opts}) do
    history_config_specs(opts) ++ BeamWeaver.Runnable.config_specs(runnable)
  end

  def input_schema(%__MODULE__{opts: opts}) do
    case Keyword.get(opts, :input_messages_key) do
      nil ->
        %{
          "title" => "RunnableWithChatHistoryInput",
          "anyOf" => [
            message_schema(),
            %{"type" => "array", "items" => message_schema()},
            %{"type" => "string"}
          ]
        }

      input_key ->
        %{
          "title" => "RunnableWithChatHistoryInput",
          "type" => "object",
          "properties" => %{
            to_string(input_key) => %{
              "anyOf" => [
                message_schema(),
                %{"type" => "array", "items" => message_schema()},
                %{"type" => "string"}
              ]
            }
          },
          "required" => [to_string(input_key)]
        }
    end
  end

  def output_schema(%__MODULE__{runnable: runnable}) do
    case BeamWeaver.Runnable.output_schema(runnable) do
      %{"type" => "any"} -> %{"title" => "RunnableWithChatHistoryOutput", "type" => "object"}
      schema -> schema
    end
  end

  defp session(%__MODULE__{opts: opts}, run_opts) do
    history = Keyword.fetch!(opts, :history)
    config = BeamWeaver.Runnable.Config.normalize(run_opts)
    session_key = Keyword.get(opts, :session_key, :session_id)

    if is_function(history, 0) do
      resolve_history(history, nil, config, opts)
    else
      session_from_config(history, config, session_key, opts)
    end
  end

  defp session_from_config(history, config, session_key, opts) do
    case Map.fetch(config.configurable, session_key) do
      :error ->
        case Map.fetch(config.configurable, to_string(session_key)) do
          {:ok, session_id} ->
            resolve_history(history, session_id, config, opts)

          :error ->
            missing_session(session_key)
        end

      {:ok, session_id} ->
        resolve_history(history, session_id, config, opts)
    end
  end

  defp resolve_history(factory, _session_id, _config, _opts) when is_function(factory, 0) do
    case factory.() do
      {:ok, session} -> {:ok, session}
      session -> {:ok, session}
    end
  end

  defp resolve_history(factory, session_id, config, opts) when is_function(factory, 1) do
    input =
      case Keyword.get(opts, :history_factory_input) || Keyword.get(opts, :factory_input) ||
             config.opts[:history_factory_input] || config.opts[:factory_input] do
        :configurable -> config.configurable
        _other -> session_id
      end

    {:ok, factory.(input)}
  end

  defp resolve_history(%{__struct__: module} = store, session_id, _config, _opts) do
    cond do
      function_exported?(module, :for_session, 2) -> {:ok, module.for_session(store, session_id)}
      function_exported?(module, :get_messages, 1) -> {:ok, store}
      true -> unsupported_history(module)
    end
  end

  defp resolve_history(module, session_id, _config, _opts) when is_atom(module) do
    cond do
      function_exported?(module, :for_session, 1) -> {:ok, module.for_session(session_id)}
      function_exported?(module, :get_messages, 1) -> {:ok, module}
      true -> unsupported_history(module)
    end
  end

  defp resolve_history(_factory, _session_id, _config, _opts), do: unsupported_history(nil)

  defp prepare_input(input, history, opts) do
    input_key = Keyword.get(opts, :input_messages_key)
    history_key = Keyword.get(opts, :history_messages_key)

    cond do
      (is_map(input) and input_key) && history_key ->
        current = messages_from(Map.get(input, input_key, []))
        {:ok, Map.put(input, history_key, history), current}

      is_map(input) and input_key ->
        current = messages_from(Map.get(input, input_key, []))
        {:ok, Map.put(input, input_key, history ++ current), current}

      true ->
        current = messages_from(input)
        {:ok, history ++ current, current}
    end
  end

  defp output_messages(output, opts) do
    output_key = Keyword.get(opts, :output_messages_key)

    output =
      if is_map(output) and output_key,
        do: Map.get(output, output_key, []),
        else: output

    assistant_messages_from(output)
  end

  defp messages_from(value, default_role \\ :user)
  defp messages_from(nil, _role), do: []
  defp messages_from(%Message{} = message, _role), do: [message]

  defp messages_from(messages, _role) when is_list(messages),
    do: Enum.flat_map(messages, &messages_from(&1))

  defp messages_from(text, _role) when is_binary(text), do: [Message.user(text)]
  defp messages_from(other, _role), do: [Message.user(to_string(other))]

  defp assistant_messages_from(nil), do: {:ok, []}
  defp assistant_messages_from(%Message{} = message), do: {:ok, [message]}
  defp assistant_messages_from(text) when is_binary(text), do: {:ok, [Message.assistant(text)]}

  defp assistant_messages_from(messages) when is_list(messages) do
    BeamWeaver.Result.flat_traverse(messages, &assistant_messages_from/1)
  end

  defp assistant_messages_from(other) do
    {:error,
     Error.new(
       :invalid_message_history_output,
       "history output must be a message, string, or list of messages",
       %{value: inspect(other)}
     )}
  end

  defp history_config_specs(opts) do
    cond do
      is_function(Keyword.get(opts, :history), 0) ->
        []

      specs = Keyword.get(opts, :config_specs) || Keyword.get(opts, :history_factory_config) ->
        Enum.map(List.wrap(specs), &normalize_config_spec/1)

      true ->
        session_key = Keyword.get(opts, :session_key, :session_id)

        [
          %ConfigSpec{
            id: to_string(session_key),
            field: session_key,
            name: "Session ID",
            description: "Conversation/session key for chat history",
            required: true
          }
        ]
    end
  end

  defp normalize_config_spec(%ConfigSpec{} = spec), do: spec
  defp normalize_config_spec(%ConfigField{} = field), do: ConfigSpec.from_field(field)

  defp normalize_config_spec(field) when is_atom(field) or is_binary(field) do
    %ConfigSpec{id: to_string(field), field: field, required: true}
  end

  defp normalize_config_spec(opts) when is_list(opts) do
    id = Keyword.fetch!(opts, :id)

    %ConfigSpec{
      id: to_string(id),
      field: Keyword.get(opts, :field, id),
      name: Keyword.get(opts, :name),
      description: Keyword.get(opts, :description),
      default: Keyword.get(opts, :default),
      required: Keyword.get(opts, :required, true)
    }
  end

  defp normalize_config_spec(map) when is_map(map) do
    id = Map.get(map, :id) || Map.fetch!(map, "id")
    required = map_get(map, :required, true)

    %ConfigSpec{
      id: to_string(id),
      field: Map.get(map, :field) || Map.get(map, "field") || id,
      name: Map.get(map, :name) || Map.get(map, "name"),
      description: Map.get(map, :description) || Map.get(map, "description"),
      default: Map.get(map, :default) || Map.get(map, "default"),
      required: required
    }
  end

  defp map_get(map, field, default) do
    string_field = to_string(field)

    cond do
      Map.has_key?(map, field) -> Map.fetch!(map, field)
      Map.has_key?(map, string_field) -> Map.fetch!(map, string_field)
      true -> default
    end
  end

  defp message_schema do
    %{
      "type" => "object",
      "properties" => %{
        "role" => %{"type" => "string"},
        "content" => %{"anyOf" => [%{"type" => "string"}, %{"type" => "array"}]}
      },
      "required" => ["role", "content"]
    }
  end

  defp append_after_stream(stream, session, input_messages, opts) do
    done = make_ref()

    Stream.transform(
      Stream.concat(stream, [done]),
      fn -> %{items: [], completed?: false} end,
      fn item, acc ->
        if item == done do
          {[], %{acc | completed?: true}}
        else
          {[item], %{acc | items: [item | acc.items]}}
        end
      end,
      fn
        %{completed?: true, items: items} ->
          output =
            items
            |> Enum.reverse()
            |> BeamWeaver.Stream.Finalize.finalize()

          case output_messages(output, opts) do
            {:ok, output_messages} ->
              ChatHistory.add_messages(session, input_messages ++ output_messages)

            {:error, _error} ->
              :ok
          end

        _acc ->
          :ok
      end
    )
  end

  defp missing_session(session_key) do
    {:error,
     Error.new(:missing_configurable, "history session key is missing", %{
       session_key: session_key
     })}
  end

  defp unsupported_history(module) do
    {:error,
     Error.new(
       :unsupported_chat_history,
       "history source cannot create a chat history session",
       %{
         module: module
       }
     )}
  end
end

defimpl BeamWeaver.Runnable.Introspect, for: BeamWeaver.Runnable.MessageHistory do
  def graph(%{runnable: runnable}, opts), do: BeamWeaver.Runnable.get_graph(runnable, opts)
  def input_schema(history), do: BeamWeaver.Runnable.MessageHistory.input_schema(history)
  def output_schema(history), do: BeamWeaver.Runnable.MessageHistory.output_schema(history)
  def config_specs(history), do: BeamWeaver.Runnable.MessageHistory.config_specs(history)
end
