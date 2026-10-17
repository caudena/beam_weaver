defmodule BeamWeaver.Core.Tool do
  @moduledoc """
  Tool contract and helper struct for executable model tools.
  """

  import BeamWeaver.MapShape, only: [put_present: 3]

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Tool.Injected
  alias BeamWeaver.Core.Tool.Invocation
  alias BeamWeaver.Core.Tool.Output
  alias BeamWeaver.Core.Tool.Schema
  alias BeamWeaver.Tracing
  alias BeamWeaver.Tracing.Options, as: TraceOptions
  alias BeamWeaver.Tracing.Runner, as: TraceRunner

  @callback name(term()) :: String.t()
  @callback description(term()) :: String.t()
  @callback input_schema(term()) :: map()
  @callback injected(term()) :: map()
  @callback return_direct(term()) :: boolean()
  @callback response_format(term()) :: atom() | map() | nil
  @callback output_schema(term()) :: map() | nil
  @callback handle_tool_error(term()) :: boolean() | String.t() | (Error.t() -> term()) | nil
  @callback handle_validation_error(term()) ::
              boolean() | String.t() | (Error.t() -> term()) | nil
  @callback parse_args(term(), map()) :: :ok | {:ok, map()} | {:error, term()}
  @callback concurrent?(term()) :: boolean()
  @callback max_result_chars(term()) :: pos_integer() | :unlimited
  @callback tags(term()) :: [atom() | String.t()]
  @callback metadata(term()) :: map()
  @callback provider_opts(term()) :: keyword() | map()
  @callback invoke(term(), map(), keyword()) :: {:ok, term()} | {:error, Error.t() | term()}

  @defaults [
    {:injected, 1, %{}},
    {:return_direct, 1, false},
    {:response_format, 1, nil},
    {:output_schema, 1, nil},
    {:handle_tool_error, 1, nil},
    {:handle_validation_error, 1, nil},
    {:parse_args, 2, :ok},
    {:concurrent?, 1, true},
    {:max_result_chars, 1, :unlimited},
    {:tags, 1, []},
    {:metadata, 1, %{}},
    {:provider_opts, 1, %{}}
  ]

  # `use BeamWeaver.Core.Tool` implements the behaviour; every callback but
  # `name/1`, `description/1`, `input_schema/1`, and `invoke/3` gets a default
  # unless the module defines it.
  defmacro __using__(_opts) do
    quote do
      @behaviour BeamWeaver.Core.Tool
      @before_compile BeamWeaver.Core.Tool
    end
  end

  defmacro __before_compile__(env) do
    for {fun, arity, value} <- @defaults, not Module.defines?(env.module, {fun, arity}) do
      args = for i <- 1..arity, do: Macro.var(:"_arg#{i}", __MODULE__)

      quote do
        @doc false
        def unquote(fun)(unquote_splicing(args)), do: unquote(Macro.escape(value))
      end
    end
  end

  @doc false
  # Whether `module` implements this behaviour (directly or via `use`).
  @spec implemented_by?(module()) :: boolean()
  def implemented_by?(module) when is_atom(module), do: BeamWeaver.Behaviour.implemented_by?(module, __MODULE__)

  @enforce_keys [:name, :description, :input_schema, :handler]
  defstruct [
    :name,
    :description,
    :input_schema,
    :handler,
    :output_schema,
    :handle_tool_error,
    :handle_validation_error,
    :parse_args,
    injected: %{},
    return_direct: false,
    response_format: nil,
    concurrent?: true,
    max_result_chars: :unlimited,
    tags: [],
    metadata: %{},
    provider_opts: %{},
    artifact: nil
  ]

  @internal_trace_opt_keys [:exporter, :exporter_opts, :trace, :trace?, :trace_input, :trace_metadata]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          input_schema: map(),
          injected: map(),
          return_direct: boolean(),
          response_format: atom() | map() | nil,
          output_schema: map() | nil,
          handle_tool_error: boolean() | String.t() | (Error.t() -> term()) | nil,
          handle_validation_error: boolean() | String.t() | (Error.t() -> term()) | nil,
          parse_args: (map() -> :ok | {:ok, map()} | {:error, term()}) | nil,
          concurrent?: boolean(),
          max_result_chars: pos_integer() | :unlimited,
          tags: [atom() | String.t()],
          metadata: map(),
          provider_opts: keyword() | map(),
          artifact: term(),
          handler: (map(), keyword() -> term())
        }

  @type injected_source ::
          :state
          | {:state, atom() | String.t() | [atom() | String.t()]}
          | :store
          | :runtime
          | :tool_runtime
          | :tool_call_id
          | :context
          | :config
          | :checkpointer

  @doc """
  Builds a tool from a function.
  """
  @spec from_function(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def from_function(opts) do
    name = Keyword.get(opts, :name)
    description = Keyword.get(opts, :description)
    input_schema = Keyword.get(opts, :input_schema)
    handler = Keyword.get(opts, :handler)
    injected = Keyword.get(opts, :injected, %{})
    return_direct = Keyword.get(opts, :return_direct, false)
    response_format = Keyword.get(opts, :response_format)
    output_schema = Keyword.get(opts, :output_schema)
    handle_tool_error = Keyword.get(opts, :handle_tool_error)
    handle_validation_error = Keyword.get(opts, :handle_validation_error)
    parse_args = Keyword.get(opts, :parse_args)
    concurrent? = Keyword.get(opts, :concurrent, true)
    max_result_chars = Keyword.get(opts, :max_result_chars, :unlimited)
    tags = Keyword.get(opts, :tags, [])
    metadata = Keyword.get(opts, :metadata, %{})
    provider_opts = Keyword.get(opts, :provider_opts, %{})
    artifact = Keyword.get(opts, :artifact)

    cond do
      not valid_name?(name) ->
        {:error, Error.new(:invalid_tool, "tool name is required")}

      not is_binary(description) or description == "" ->
        {:error, Error.new(:invalid_tool, "tool description is required")}

      not is_map(input_schema) ->
        {:error, Error.new(:invalid_tool, "tool input_schema must be a map")}

      not is_function(handler, 2) ->
        {:error, Error.new(:invalid_tool, "tool handler must accept input and opts")}

      output_schema != nil and not is_map(output_schema) ->
        {:error, Error.new(:invalid_tool, "tool output_schema must be a map")}

      parse_args != nil and not is_function(parse_args, 1) ->
        {:error, Error.new(:invalid_tool, "tool parse_args must accept args")}

      not is_boolean(concurrent?) ->
        {:error, Error.new(:invalid_tool, "tool concurrent option must be a boolean")}

      not valid_max_result_chars?(max_result_chars) ->
        {:error,
         Error.new(
           :invalid_tool,
           "tool max_result_chars must be :unlimited or a positive integer"
         )}

      not is_list(tags) ->
        {:error, Error.new(:invalid_tool, "tool tags must be a list")}

      not is_map(metadata) ->
        {:error, Error.new(:invalid_tool, "tool metadata must be a map")}

      not (is_map(provider_opts) or Keyword.keyword?(provider_opts)) ->
        {:error, Error.new(:invalid_tool, "tool provider_opts must be a map or keyword list")}

      true ->
        with {:ok, injected} <- Injected.normalize(injected) do
          {:ok,
           %__MODULE__{
             name: name,
             description: description,
             input_schema: input_schema,
             injected: injected,
             return_direct: return_direct == true,
             response_format: response_format,
             output_schema: output_schema,
             handle_tool_error: handle_tool_error,
             handle_validation_error: handle_validation_error,
             parse_args: parse_args,
             concurrent?: concurrent?,
             max_result_chars: max_result_chars,
             tags: tags,
             metadata: metadata,
             provider_opts: provider_opts,
             artifact: artifact,
             handler: handler
           }}
        end
    end
  end

  @doc """
  Builds a tool and raises on invalid input.
  """
  @spec from_function!(keyword()) :: t()
  def from_function!(opts), do: opts |> from_function() |> BeamWeaver.Policy.bang()

  @doc """
  Returns a tool name for structs implementing this behaviour or `%Tool{}`.
  """
  @spec name(term()) :: String.t()
  def name(%__MODULE__{name: name}), do: name
  def name(tool), do: callback(tool, :name)

  @doc """
  Returns a tool description.
  """
  @spec description(term()) :: String.t()
  def description(%__MODULE__{description: description}), do: description
  def description(tool), do: callback(tool, :description)

  @doc """
  Returns a tool input schema.
  """
  @spec input_schema(term()) :: map()
  def input_schema(tool) do
    tool
    |> raw_input_schema()
    |> Schema.public_input(Map.keys(injected(tool)))
  end

  @doc """
  Returns a tool input schema including runtime-injected arguments.
  """
  @spec raw_input_schema(term()) :: map()
  def raw_input_schema(%__MODULE__{input_schema: input_schema}), do: input_schema
  def raw_input_schema(tool), do: callback(tool, :input_schema)

  @doc """
  Returns runtime-injected tool arguments.
  """
  @spec injected(term()) :: %{optional(atom() | String.t()) => injected_source()}
  def injected(%__MODULE__{injected: injected}), do: injected

  def injected(tool) do
    tool
    |> callback(:injected)
    |> Injected.normalize!()
  end

  @doc """
  Returns whether an agent loop should stop immediately after this tool succeeds.
  """
  @spec return_direct(term()) :: boolean()
  def return_direct(%__MODULE__{return_direct: return_direct}), do: return_direct == true

  def return_direct(tool) do
    callback(tool, :return_direct) == true
  end

  @doc """
  Returns the tool response format declaration, if any.
  """
  @spec response_format(term()) :: atom() | map() | nil
  def response_format(%__MODULE__{response_format: response_format}), do: response_format

  def response_format(tool) do
    callback(tool, :response_format)
  end

  @doc """
  Returns the tool output schema, if any.
  """
  @spec output_schema(term()) :: map() | nil
  def output_schema(%__MODULE__{output_schema: output_schema}), do: output_schema

  def output_schema(tool) do
    callback(tool, :output_schema)
  end

  @doc """
  Returns the tool exception formatting policy, if any.
  """
  @spec handle_tool_error(term()) :: boolean() | String.t() | (Error.t() -> term()) | nil
  def handle_tool_error(%__MODULE__{handle_tool_error: policy}), do: policy

  def handle_tool_error(tool) do
    callback(tool, :handle_tool_error)
  end

  @doc """
  Returns the tool validation-error formatting policy, if any.
  """
  @spec handle_validation_error(term()) :: boolean() | String.t() | (Error.t() -> term()) | nil
  def handle_validation_error(%__MODULE__{handle_validation_error: policy}), do: policy

  def handle_validation_error(tool) do
    callback(tool, :handle_validation_error)
  end

  @doc """
  Parses raw model-provided arguments before schema validation.
  """
  @spec parse_args(term(), map()) :: :ok | {:ok, map()} | {:error, term()}
  def parse_args(%__MODULE__{parse_args: nil}, _args), do: :ok

  def parse_args(%__MODULE__{parse_args: parser}, args) when is_function(parser, 1),
    do: parser.(args)

  def parse_args(tool, args) do
    callback(tool, :parse_args, [args])
  end

  @doc """
  Returns whether ToolNode may execute this tool concurrently with adjacent tool calls.
  """
  @spec concurrent?(term()) :: boolean()
  def concurrent?(%__MODULE__{concurrent?: concurrent?}), do: concurrent? == true

  def concurrent?(tool) do
    callback(tool, :concurrent?) == true
  end

  @doc """
  Returns the model-visible textual result length limit for this tool.
  """
  @spec max_result_chars(term()) :: pos_integer() | :unlimited
  def max_result_chars(%__MODULE__{max_result_chars: max_result_chars}), do: max_result_chars

  def max_result_chars(tool) do
    case callback(tool, :max_result_chars) do
      value when is_integer(value) and value > 0 -> value
      _unlimited -> :unlimited
    end
  end

  @doc """
  Returns tool tags.
  """
  @spec tags(term()) :: [atom() | String.t()]
  def tags(%__MODULE__{tags: tags}), do: tags

  def tags(tool) do
    callback(tool, :tags)
  end

  @doc """
  Returns tool metadata.
  """
  @spec metadata(term()) :: map()
  def metadata(%__MODULE__{metadata: metadata}), do: metadata

  def metadata(tool) do
    callback(tool, :metadata)
  end

  @doc """
  Returns provider-specific options attached to this tool.
  """
  @spec provider_opts(term()) :: keyword() | map()
  def provider_opts(%__MODULE__{provider_opts: provider_opts}), do: provider_opts

  def provider_opts(tool) do
    callback(tool, :provider_opts)
  end

  @doc """
  Returns the public argument schema properties for a tool.
  """
  @spec args(term()) :: map()
  def args(tool) do
    tool
    |> input_schema()
    |> Schema.properties()
  end

  @doc """
  Returns whether a tool exposes exactly one non-injected input field.
  """
  @spec single_input?(term()) :: boolean()
  def single_input?(tool), do: map_size(args(tool)) == 1

  @doc "Deprecated. Use `single_input?/1` instead."
  @deprecated "Use single_input?/1 instead"
  @spec is_single_input(term()) :: boolean()
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_single_input(tool), do: single_input?(tool)

  @doc """
  Returns the model-visible tool call schema.

  Runtime-injected arguments are filtered out of the parameters.
  """
  @spec tool_call_schema(term()) :: map()
  def tool_call_schema(tool) do
    %{
      "name" => name(tool),
      "description" => description(tool),
      "parameters" => input_schema(tool)
    }
  end

  @doc """
  Invokes a tool after validating required input keys.
  """
  @spec invoke(term(), map(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def invoke(tool, input, opts \\ []) do
    trace_tool_call(tool, input, opts, &Invocation.invoke(tool, input, &1))
  end

  @doc """
  Formats a raw tool result as a tool message when a tool-call ID is present.

  Native `%BeamWeaver.Core.Message{role: :tool}` and `%ToolResult{}` values are
  treated as structured tool outputs. Non-message lists are stringified unless
  every element is already a structured tool output.
  """
  @spec format_output(term(), keyword()) :: term()
  def format_output(content, opts \\ []), do: Output.format(content, opts)

  @doc """
  Validates required keys, closed properties, basic JSON types, and declared
  string, numeric, and collection bounds.
  """
  @spec validate_input(map(), map()) :: :ok | {:error, Error.t()}
  def validate_input(schema, input), do: Schema.validate(schema, input)

  @doc """
  Validates a tool input and returns its normalized JSON object with string keys.

  Atom and string keys that normalize to the same name are rejected.
  """
  @spec normalize_input(map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def normalize_input(schema, input), do: Schema.normalize(schema, input)

  defp trace_tool_call(tool, input, opts, fun) when is_function(fun, 1) do
    call_opts = Keyword.drop(opts, @internal_trace_opt_keys)

    if BeamWeaver.Core.ChatModel.trace?(opts) do
      exporter_opts = Keyword.take(opts, [:exporter, :exporter_opts])

      TraceRunner.run(
        name(tool),
        [
          kind: :tool,
          inputs: trace_inputs(tool, input, opts),
          tags: [:tool] ++ tags(tool),
          metadata: tool_trace_metadata(tool, input, opts)
        ],
        exporter_opts,
        fn -> fun.(call_opts) end,
        fn run, result ->
          case result do
            {:ok, result} = ok ->
              Tracing.finish_run(
                run,
                exporter_opts ++ [outputs: %{output: result}]
              )

              ok

            {:error, %Error{} = error} = tagged_error ->
              Tracing.fail_run(run, error, exporter_opts)
              tagged_error

            other ->
              error =
                Error.new(:invalid_tool_result, "tool invocation returned an invalid result", %{
                  result: inspect(other)
                })

              Tracing.fail_run(run, error, exporter_opts)
              other
          end
        end
      )
    else
      fun.(call_opts)
    end
  end

  defp tool_trace_metadata(tool, input, opts) do
    tool
    |> metadata()
    |> Map.merge(%{
      tool_name: name(tool),
      description: description(tool)
    })
    |> Map.merge(Keyword.get(opts, :trace_metadata, %{}) || %{})
    |> TraceOptions.metadata(Keyword.get(opts, :trace))
    |> put_present(:tool_call_id, tool_call_id(input, opts))
  end

  defp trace_inputs(tool, input, opts) do
    trace_input = Keyword.get(opts, :trace_input, default_trace_input(tool, input))
    public_trace_input(tool, trace_input)
  end

  defp default_trace_input(_tool, input) when is_map(input) do
    if Invocation.tool_call_input?(input) do
      args = BeamWeaver.MapAccess.get(input, :args)
      if is_map(args), do: args, else: %{"input" => args}
    else
      input
    end
  end

  defp default_trace_input(tool, input) do
    if single_input?(tool) do
      [key] = tool |> args() |> Map.keys()
      %{key => input}
    else
      %{"input" => input}
    end
  end

  defp public_trace_input(tool, input) when is_map(input), do: Invocation.without_injected(input, injected(tool))

  defp public_trace_input(_tool, input), do: %{"input" => input}

  defp tool_call_id(input, opts) when is_map(input) do
    Keyword.get(opts, :tool_call_id) || BeamWeaver.MapAccess.get(input, :id)
  end

  defp tool_call_id(_input, opts), do: Keyword.get(opts, :tool_call_id)

  defp valid_name?(name), do: is_binary(name) and name != ""
  defp valid_max_result_chars?(:unlimited), do: true
  defp valid_max_result_chars?(value), do: is_integer(value) and value > 0

  defp callback(tool, callback, extra_args \\ []) do
    {module, first_arg} = callback_target(tool)
    apply(module, callback, [first_arg | extra_args])
  end

  defp callback_target(module) when is_atom(module), do: {module, module}
  defp callback_target(%{__struct__: module} = tool), do: {module, tool}
end
