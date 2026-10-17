defmodule BeamWeaver.Provider.ChatModel do
  @moduledoc false

  # Shared invoke/stream flow for the provider chat models. A model module
  # `use`s this and implements the callbacks below; `ChatRuntime` builds the
  # request body, sends it, decodes the response and parses structured output.
  #
  #     use BeamWeaver.Provider.ChatModel, stream_source: :moonshot_chat_completions
  #
  # `exact_stream_events: true` routes `stream_exact_typed_events/3` through
  # `send_request(:exact_stream_events, ...)`; otherwise it is unsupported.

  alias BeamWeaver.Core.Message

  @type body :: map() | binary()
  @type call :: :invoke | :stream | :stream_response | :stream_events | :exact_stream_events

  @callback request_body(model :: struct(), [Message.t()], keyword()) :: {:ok, body()} | {:error, term()}
  @callback send_request(call(), model :: struct(), body(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback decode_response(response :: term(), keyword()) :: {:ok, Message.t()} | {:error, term()}
  @callback parse_response(model :: struct(), Message.t(), keyword()) :: {:ok, Message.t()} | {:error, term()}
  @callback stream_metadata(model :: struct(), body(), keyword()) :: map()
  @callback forced_tool_choice?(model :: struct(), keyword()) :: boolean()

  defmacro __using__(opts) do
    source = Keyword.get(opts, :stream_source)
    exact? = Keyword.get(opts, :exact_stream_events, false)

    quote do
      @behaviour BeamWeaver.Core.ChatModel
      @behaviour BeamWeaver.Provider.ChatModel

      alias BeamWeaver.Provider.ChatModel.Options, as: ChatOptions
      alias BeamWeaver.Provider.ChatRuntime

      @spec model_name(t()) :: String.t()
      def model_name(%__MODULE__{model: model}), do: model

      @spec should_stream?(t(), keyword()) :: boolean()
      def should_stream?(%__MODULE__{} = model, opts \\ []), do: ChatOptions.should_stream?(model, opts)

      def model_id(%__MODULE__{model: model}), do: model
      def profile(%__MODULE__{profile: profile}), do: profile

      @impl BeamWeaver.Core.ChatModel
      def resolve_invocation_model(%__MODULE__{} = model, _opts), do: {:ok, model}

      @impl BeamWeaver.Core.ChatModel
      def invoke(%__MODULE__{} = model, messages, opts \\ []) do
        with {:ok, model} <- resolve_invocation_model(model, opts),
             do: ChatRuntime.invoke(__MODULE__, model, messages, opts)
      end

      @impl BeamWeaver.Core.ChatModel
      def stream(%__MODULE__{} = model, messages, opts \\ []) do
        with {:ok, model} <- resolve_invocation_model(model, opts),
             do: ChatRuntime.stream(__MODULE__, model, messages, opts)
      end

      def stream_response(%__MODULE__{} = model, messages, opts \\ []) do
        with {:ok, model} <- resolve_invocation_model(model, opts),
             do: ChatRuntime.stream_response(__MODULE__, model, messages, opts)
      end

      @impl BeamWeaver.Core.ChatModel
      def stream_events(%__MODULE__{} = model, messages, opts \\ []),
        do: stream_typed_events(model, messages, opts)

      @impl BeamWeaver.Core.ChatModel
      def stream_typed_events(%__MODULE__{} = model, messages, opts \\ []) do
        with {:ok, model} <- resolve_invocation_model(model, opts),
             do: ChatRuntime.stream_events(__MODULE__, unquote(source), model, messages, opts)
      end

      @impl BeamWeaver.Core.ChatModel
      if unquote(exact?) do
        def stream_exact_typed_events(%__MODULE__{} = model, body, opts \\ []) when is_binary(body),
          do: ChatRuntime.stream_exact_events(__MODULE__, unquote(source), model, body, opts)
      else
        def stream_exact_typed_events(%__MODULE__{}, body, _opts \\ []) when is_binary(body),
          do:
            {:error,
             BeamWeaver.Core.Error.new(:unsupported_feature, "provider does not support exact typed stream events")}
      end

      @impl BeamWeaver.Provider.ChatModel
      def parse_response(_model, message, _opts), do: {:ok, message}

      @impl BeamWeaver.Provider.ChatModel
      def stream_metadata(_model, _body, _opts), do: %{}

      # Whether a call with these options may force a tool call
      # (`tool_choice: :required`).
      @impl BeamWeaver.Provider.ChatModel
      def forced_tool_choice?(_model, _opts), do: true

      defoverridable resolve_invocation_model: 2,
                     stream_events: 2,
                     stream_events: 3,
                     stream_typed_events: 2,
                     stream_typed_events: 3,
                     stream_exact_typed_events: 2,
                     stream_exact_typed_events: 3,
                     parse_response: 3,
                     stream_metadata: 3,
                     forced_tool_choice?: 2
    end
  end
end
