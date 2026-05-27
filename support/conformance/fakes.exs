defmodule BeamWeaver.TestSupport.Conformance.Fakes.ChatModel do
  @behaviour BeamWeaver.Core.ChatModel

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.LanguageModel
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Core.Messages.AIChunk
  alias BeamWeaver.Core.Messages.ToolCallChunk
  alias BeamWeaver.Models.ParamPolicy
  alias BeamWeaver.Stream
  alias BeamWeaver.Stream.Events

  defstruct reply: "hello",
            usage_metadata: nil,
            stream_chunks: nil,
            stream_events: nil,
            profile: nil,
            tokenizer: nil,
            param_policy: nil,
            tool_calls: [],
            structured_response: nil,
            error: nil,
            parent: nil

  def from_config(opts \\ []) do
    %__MODULE__{
      reply:
        BeamWeaver.Config.get(
          [:test_support, Keyword.get(opts, :reply_config_key, :fake_chat_reply)],
          "env"
        ),
      usage_metadata: Keyword.get(opts, :usage_metadata),
      profile: Keyword.get(opts, :profile),
      tokenizer: Keyword.get(opts, :tokenizer),
      param_policy: Keyword.get(opts, :param_policy),
      parent: Keyword.get(opts, :parent)
    }
  end

  def from_env(opts \\ []), do: from_config(opts)

  def lifecycle_stream_events(text \\ "stream") do
    [
      Stream.envelope(%Events.Token{text: text}, metadata: %{provider: :fake, lifecycle: :token}),
      Stream.envelope(
        %Events.MessageChunk{chunk: %AIChunk{content: text}},
        metadata: %{provider: :fake, lifecycle: :chunk}
      ),
      Stream.envelope(%Events.Done{}, metadata: %{provider: :fake, lifecycle: :done})
    ]
  end

  @impl true
  def invoke(%__MODULE__{} = model, messages, opts) do
    with :ok <-
           ParamPolicy.validate(
             model.profile,
             opts,
             Keyword.get(opts, :param_policy, model.param_policy)
           ) do
      if model.parent, do: send(model.parent, {:fake_chat_model_call, messages, opts})

      last_user_text =
        messages
        |> Enum.reverse()
        |> Enum.find(&(&1.role == :user))
        |> Message.text()

      message =
        response_message(model, "#{model.reply}: #{last_user_text}", opts)

      {:ok, message}
    end
  end

  @impl true
  def stream(%__MODULE__{} = model, messages, opts) do
    with :ok <-
           ParamPolicy.validate(
             model.profile,
             opts,
             Keyword.get(opts, :param_policy, model.param_policy)
           ) do
      if model.parent, do: send(model.parent, {:fake_chat_model_stream, messages, opts})

      cond do
        model.stream_chunks ->
          {:ok, model.stream_chunks}

        true ->
          with {:ok, message} <- invoke(%{model | parent: nil}, messages, opts),
               do: {:ok, [message]}
      end
    end
  end

  @impl true
  def stream_events(%__MODULE__{} = model, messages, opts) do
    with :ok <-
           ParamPolicy.validate(
             model.profile,
             opts,
             Keyword.get(opts, :param_policy, model.param_policy)
           ) do
      cond do
        model.stream_events ->
          {:ok, model.stream_events}

        true ->
          with {:ok, message} <- invoke(%{model | parent: nil}, messages, opts) do
            {:ok,
             [
               Stream.envelope(%Events.Message{message: message}, metadata: %{provider: :fake}),
               Stream.envelope(%Events.Done{}, metadata: %{provider: :fake})
             ]}
          end
      end
    end
  end

  def count_tokens(%__MODULE__{tokenizer: nil}, input, _opts),
    do: {:ok, LanguageModel.count_tokens_approximately(input)}

  def count_tokens(%__MODULE__{tokenizer: tokenizer}, input, opts),
    do: LanguageModel.count_tokens({:tokenizer, tokenizer}, input, opts)

  defp response_message(%__MODULE__{error: error}, _text, _opts) when not is_nil(error) do
    raise error
  end

  defp response_message(%__MODULE__{structured_response: response} = model, text, opts)
       when not is_nil(response) do
    cond do
      Keyword.has_key?(opts, :response_format) or Keyword.has_key?(opts, :structured_output) ->
        Message.assistant(BeamWeaver.JSON.encode!(response),
          metadata: %{"parsed" => stringify_keys(response)},
          response_metadata: response_metadata(model),
          usage_metadata: model.usage_metadata,
          tool_calls: []
        )

      true ->
        Message.assistant(text,
          response_metadata: response_metadata(model),
          usage_metadata: model.usage_metadata,
          tool_calls: normalize_tool_calls(model.tool_calls, opts)
        )
    end
  end

  defp response_message(%__MODULE__{} = model, text, opts) do
    Message.assistant(text,
      response_metadata: response_metadata(model),
      usage_metadata: model.usage_metadata,
      tool_calls: normalize_tool_calls(model.tool_calls, opts)
    )
  end

  defp response_metadata(%__MODULE__{profile: %{id: id}}) when is_binary(id),
    do: %{"model_name" => id}

  defp response_metadata(_model), do: %{}

  defp normalize_tool_calls(:from_tools, opts) do
    opts
    |> Keyword.get(:tools, [])
    |> List.wrap()
    |> tools_for_choice(Keyword.get(opts, :tool_choice))
    |> Enum.with_index()
    |> Enum.map(fn {tool, index} ->
      name = Tool.name(tool)

      %{
        id: "call_#{name}_#{index}",
        name: name,
        args: sample_args(Tool.input_schema(tool)),
        type: "tool_call"
      }
    end)
  end

  defp normalize_tool_calls(calls, _opts) do
    Enum.map(calls, fn call ->
      call
      |> Map.new()
      |> Map.update(:args, %{}, & &1)
      |> Map.update(:arguments, Map.get(call, :args) || Map.get(call, "args") || %{}, & &1)
    end)
  end

  defp tools_for_choice(tools, choice) when choice in [nil, false, :auto, "auto", :any, "any"],
    do: tools

  defp tools_for_choice(tools, choice) when is_binary(choice) do
    case Enum.find(tools, &(Tool.name(&1) == choice)) do
      nil -> tools
      tool -> [tool]
    end
  end

  defp tools_for_choice(tools, %{name: name}), do: tools_for_choice(tools, name)
  defp tools_for_choice(tools, %{"name" => name}), do: tools_for_choice(tools, name)
  defp tools_for_choice(tools, _choice), do: tools

  defp sample_args(schema) do
    schema
    |> required_keys()
    |> Map.new(fn key -> {key, sample_value(key)} end)
  end

  defp required_keys(schema) when is_map(schema) do
    schema
    |> Map.get(:required, Map.get(schema, "required", []))
    |> Enum.map(&to_string/1)
  end

  defp required_keys(_schema), do: []

  defp sample_value("customer_name"), do: "你好啊集团"
  defp sample_value("description"), do: "Chinese technology company"
  defp sample_value("answer_style"), do: "pirate"
  defp sample_value("location"), do: "San Francisco"
  defp sample_value("zone"), do: "UTC"
  defp sample_value("query"), do: "hello"
  defp sample_value(_key), do: "value"

  def streamed_invalid_tool_call do
    [
      %AIChunk{
        tool_call_chunks: [
          %ToolCallChunk{id: "call_bad", index: 0, name: "lookup", args: "{\"query\""}
        ]
      }
    ]
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value
end

defmodule BeamWeaver.TestSupport.Conformance.Fakes.InvalidChatModel do
  @behaviour BeamWeaver.Core.ChatModel

  defstruct []

  @impl true
  def invoke(_model, _messages, _opts),
    do: {:ok, %{role: :assistant, content: "not a BeamWeaver message"}}
end

defmodule BeamWeaver.TestSupport.Conformance.Fakes.EmbeddingModel do
  @behaviour BeamWeaver.Core.EmbeddingModel

  alias BeamWeaver.Models.ParamPolicy

  defstruct dimensions: 3, profile: nil, param_policy: nil, error: nil, parent: nil

  def from_config(opts \\ []) do
    dimensions =
      [:test_support, Keyword.get(opts, :dimensions_config_key, :fake_embedding_dimensions)]
      |> BeamWeaver.Config.get()
      |> case do
        nil -> Keyword.get(opts, :dimensions, 3)
        value -> String.to_integer(value)
      end

    %__MODULE__{
      dimensions: dimensions,
      profile: Keyword.get(opts, :profile),
      param_policy: Keyword.get(opts, :param_policy),
      parent: Keyword.get(opts, :parent)
    }
  end

  def from_env(opts \\ []), do: from_config(opts)

  @impl true
  def embed_documents(%__MODULE__{} = model, documents, opts) do
    with :ok <-
           ParamPolicy.validate(
             model.profile,
             opts,
             Keyword.get(opts, :param_policy, model.param_policy)
           ) do
      if model.parent, do: send(model.parent, {:fake_embedding_documents, documents, opts})
      maybe_error(model) || {:ok, Enum.map(documents, &vector(&1, model.dimensions))}
    end
  end

  @impl true
  def embed_query(%__MODULE__{} = model, query, opts) do
    with :ok <-
           ParamPolicy.validate(
             model.profile,
             opts,
             Keyword.get(opts, :param_policy, model.param_policy)
           ) do
      if model.parent, do: send(model.parent, {:fake_embedding_query, query, opts})
      maybe_error(model) || {:ok, vector(query, model.dimensions)}
    end
  end

  defp maybe_error(%__MODULE__{error: nil}), do: nil
  defp maybe_error(%__MODULE__{error: error}), do: {:error, error}

  defp vector(text, dimensions) do
    seed = byte_size(text)
    Enum.map(1..dimensions, &(seed + &1 / 10))
  end
end

defmodule BeamWeaver.TestSupport.Conformance.Fakes.BadCountEmbeddingModel do
  @behaviour BeamWeaver.Core.EmbeddingModel

  defstruct []

  @impl true
  def embed_documents(_model, _documents, _opts), do: {:ok, [[1.0]]}

  @impl true
  def embed_query(_model, _query, _opts), do: {:ok, [1.0]}
end

defmodule BeamWeaver.TestSupport.Conformance.Fakes.BadVectorEmbeddingModel do
  @behaviour BeamWeaver.Core.EmbeddingModel

  defstruct []

  @impl true
  def embed_documents(_model, documents, _opts), do: {:ok, Enum.map(documents, fn _ -> [1.0] end)}

  @impl true
  def embed_query(_model, _query, _opts), do: {:ok, ["not numeric"]}
end

defmodule BeamWeaver.TestSupport.Conformance.Fakes.LLM do
  @behaviour BeamWeaver.Core.LLM

  alias BeamWeaver.Core.LanguageModel
  alias BeamWeaver.Models.ParamPolicy

  defstruct prefix: "completion",
            stream_chunks: nil,
            profile: nil,
            tokenizer: nil,
            param_policy: nil,
            error: nil,
            parent: nil

  def from_config(opts \\ []) do
    %__MODULE__{
      prefix:
        BeamWeaver.Config.get(
          [:test_support, Keyword.get(opts, :prefix_config_key, :fake_llm_prefix)],
          "env"
        ),
      stream_chunks: Keyword.get(opts, :stream_chunks),
      profile: Keyword.get(opts, :profile),
      tokenizer: Keyword.get(opts, :tokenizer),
      param_policy: Keyword.get(opts, :param_policy),
      parent: Keyword.get(opts, :parent)
    }
  end

  def from_env(opts \\ []), do: from_config(opts)

  @impl true
  def complete(%__MODULE__{} = model, prompt, opts) do
    with :ok <-
           ParamPolicy.validate(
             model.profile,
             opts,
             Keyword.get(opts, :param_policy, model.param_policy)
           ) do
      if model.parent, do: send(model.parent, {:fake_llm_call, prompt, opts})
      maybe_error(model) || {:ok, "#{model.prefix}: #{prompt}"}
    end
  end

  def stream(%__MODULE__{stream_chunks: chunks} = model, prompt, opts) when is_list(chunks) do
    with :ok <-
           ParamPolicy.validate(
             model.profile,
             opts,
             Keyword.get(opts, :param_policy, model.param_policy)
           ) do
      if model.parent, do: send(model.parent, {:fake_llm_stream, prompt, opts})
      {:ok, chunks}
    end
  end

  def stream(%__MODULE__{} = model, prompt, opts) do
    with {:ok, text} <- complete(model, prompt, opts), do: {:ok, [text]}
  end

  def count_tokens(%__MODULE__{tokenizer: nil}, input, _opts),
    do: {:ok, LanguageModel.count_tokens_approximately(input)}

  def count_tokens(%__MODULE__{tokenizer: tokenizer}, input, opts),
    do: LanguageModel.count_tokens({:tokenizer, tokenizer}, input, opts)

  defp maybe_error(%__MODULE__{error: nil}), do: nil
  defp maybe_error(%__MODULE__{error: error}), do: {:error, error}
end

defmodule BeamWeaver.TestSupport.Conformance.Fakes.BadLLM do
  @behaviour BeamWeaver.Core.LLM

  defstruct []

  @impl true
  def complete(_model, _prompt, _opts), do: {:ok, %{text: "not a string"}}
end

defmodule BeamWeaver.TestSupport.Conformance.Fakes.Tools do
  def adder do
    BeamWeaver.Core.Tool.from_function!(
      name: "adder",
      description: "Adds two numbers",
      input_schema: %{
        type: :object,
        required: [:a, :b],
        properties: %{a: %{type: :number}, b: %{type: :number}}
      },
      handler: fn input, _opts -> input.a + input.b end
    )
  end

  def injected do
    BeamWeaver.Core.Tool.from_function!(
      name: "injected",
      description: "Uses a runtime value",
      input_schema: %{
        type: :object,
        required: [:query, :runtime],
        properties: %{query: %{type: :string}, runtime: %{type: :object}}
      },
      injected: %{runtime: :runtime},
      handler: fn input, _opts -> input.query end
    )
  end

  def artifact_tool do
    BeamWeaver.Core.Tool.from_function!(
      name: "artifact_tool",
      description: "Returns content and artifact metadata",
      input_schema: %{
        type: :object,
        required: [:query],
        properties: %{query: %{type: :string}}
      },
      response_format: :content_and_artifact,
      output_schema: %{type: :object, properties: %{answer: %{type: :string}}},
      metadata: %{category: "test"},
      artifact: %{kind: "fixture"},
      handler: fn input, _opts -> %{answer: input.query} end
    )
  end

  def nested_schema_tool do
    BeamWeaver.Core.Tool.from_function!(
      name: "nested_schema",
      description: "Validates nested objects and arrays",
      input_schema: %{
        type: :object,
        required: [:items],
        properties: %{
          items: %{
            type: :array,
            items: %{
              type: :object,
              required: [:name, :quantity],
              properties: %{
                name: %{type: :string},
                quantity: %{type: :integer},
                unit: %{type: [:string, :null]}
              }
            }
          }
        }
      },
      handler: fn input, _opts -> Enum.count(input.items) end
    )
  end

  def unsafe_provider_name_tool do
    BeamWeaver.Core.Tool.from_function!(
      name: "bad provider name",
      description: "Internal names can be more permissive than provider renderers",
      input_schema: %{type: :object, required: [], properties: %{}},
      handler: fn _input, _opts -> :ok end
    )
  end
end

defmodule BeamWeaver.TestSupport.Conformance.Fakes.Transport do
  @behaviour BeamWeaver.Transport

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Transport.Request
  alias BeamWeaver.Transport.Response

  @impl true
  def request(%Request{} = request, opts) do
    parent = Keyword.get(opts, :parent)
    if parent, do: send(parent, {:fake_transport_request, request})

    expected = next_expected(Keyword.get(opts, :expect, %{}))

    case mismatch(request, expected) do
      nil ->
        {:ok,
         Response.new(
           status: Keyword.get(opts, :status, 200),
           headers: Keyword.get(opts, :headers, []),
           body: Keyword.get(opts, :body, %{}) |> encode_body(),
           metadata: %{source: :fake_transport}
         )}

      details ->
        {:error, Error.new(:fake_transport_mismatch, "fake transport request mismatch", details)}
    end
  end

  defp mismatch(%Request{} = request, expected) do
    checks = [
      method: fn ->
        case expected[:method] || expected["method"] do
          nil -> true
          method -> normalize_method(method) == normalize_method(request.method)
        end
      end,
      path: fn ->
        case expected[:path] || expected["path"] do
          nil -> true
          path -> String.ends_with?(request.url, path)
        end
      end,
      json: fn ->
        case expected[:json] || expected["json"] do
          nil -> true
          body -> normalize_body(request.json) == normalize_body(body)
        end
      end
    ]

    failed =
      Enum.find_value(checks, fn {name, check} ->
        if check.(), do: nil, else: name
      end)

    if failed do
      request
      |> details(expected)
      |> Map.put(:failed, failed)
      |> maybe_put_json_diff(request, expected)
    end
  end

  defp next_expected({:ordered, agent}) when is_pid(agent) do
    Agent.get_and_update(agent, fn
      [next | rest] -> {next, rest}
      [] -> {%{}, []}
    end)
  end

  defp next_expected(expected), do: expected

  defp details(request, expected) do
    %{
      expected: BeamWeaver.Transport.Redactor.redact(expected),
      request:
        BeamWeaver.Transport.Redactor.redact(%{
          method: request.method,
          url: request.url,
          json: request.json
        })
    }
  end

  defp normalize_method(method), do: method |> to_string() |> String.downcase()
  defp normalize_body(body), do: BeamWeaver.JSON.decode!(BeamWeaver.JSON.encode!(body))
  defp encode_body(body) when is_binary(body), do: body
  defp encode_body(body), do: BeamWeaver.JSON.encode!(body)

  defp maybe_put_json_diff(details, %Request{} = request, expected) do
    case expected[:json] || expected["json"] do
      nil ->
        details

      expected_json when is_map(expected_json) and is_map(request.json) ->
        request_keys = request.json |> Map.keys() |> MapSet.new()
        expected_keys = expected_json |> Map.keys() |> MapSet.new()

        Map.put(details, :json_diff, %{
          missing_keys: MapSet.difference(expected_keys, request_keys) |> MapSet.to_list(),
          extra_keys: MapSet.difference(request_keys, expected_keys) |> MapSet.to_list()
        })

      _other ->
        details
    end
  end
end
