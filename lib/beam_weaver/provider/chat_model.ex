defmodule BeamWeaver.Provider.ChatModel do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      @behaviour BeamWeaver.Core.ChatModel

      alias BeamWeaver.Provider.ChatModel.Options, as: ChatOptions
      alias BeamWeaver.Provider.ChatRuntime

      @spec model_name(t()) :: String.t()
      def model_name(%__MODULE__{model: model}), do: model

      @spec should_stream?(t()) :: boolean()
      def should_stream?(model), do: should_stream?(model, [])

      @spec should_stream?(t(), keyword()) :: boolean()
      def should_stream?(%__MODULE__{} = model, opts) do
        ChatOptions.should_stream?(model, opts)
      end

      def invoke(model, messages), do: invoke(model, messages, [])

      @impl true
      def invoke(%__MODULE__{} = model, messages, opts) do
        ChatRuntime.invoke(model, messages, opts, runtime_adapter())
      end

      def async_invoke(model, messages), do: async_invoke(model, messages, [])

      def async_invoke(%__MODULE__{} = model, messages, opts) do
        ChatRuntime.async_invoke(opts, &invoke(model, messages, &1))
      end

      def async_batch(model, message_batches), do: async_batch(model, message_batches, [])

      def async_batch(%__MODULE__{} = model, message_batches, opts)
          when is_list(message_batches) do
        ChatRuntime.async_batch(message_batches, opts, &invoke(model, &1, &2))
      end

      def stream(model, messages), do: stream(model, messages, [])

      @impl true
      def stream(%__MODULE__{} = model, messages, opts) do
        ChatRuntime.stream(model, messages, opts, runtime_adapter())
      end

      def async_stream(model, messages), do: async_stream(model, messages, [])

      def async_stream(%__MODULE__{} = model, messages, opts) do
        ChatRuntime.async_stream(opts, &stream(model, messages, &1))
      end

      def stream_response(model, messages), do: stream_response(model, messages, [])

      def stream_response(%__MODULE__{} = model, messages, opts) do
        ChatRuntime.stream_response(model, messages, opts, runtime_adapter())
      end

      def async_stream_response(model, messages), do: async_stream_response(model, messages, [])

      def async_stream_response(%__MODULE__{} = model, messages, opts) do
        ChatRuntime.async_stream(opts, &stream_response(model, messages, &1))
      end

      def stream_events(model, messages), do: stream_events(model, messages, [])

      @impl true
      def stream_events(%__MODULE__{} = model, messages, opts) do
        ChatRuntime.stream_events(model, messages, opts, runtime_adapter())
      end

      def async_stream_events(model, messages), do: async_stream_events(model, messages, [])

      def async_stream_events(%__MODULE__{} = model, messages, opts) do
        ChatRuntime.async_stream(opts, &stream_events(model, messages, &1))
      end

      def stream_typed_events(model, messages), do: stream_typed_events(model, messages, [])

      @impl true
      def stream_typed_events(%__MODULE__{} = model, messages, opts) do
        ChatRuntime.stream_events(model, messages, opts, runtime_adapter())
      end

      def async_stream_typed_events(model, messages), do: async_stream_typed_events(model, messages, [])

      def async_stream_typed_events(%__MODULE__{} = model, messages, opts) do
        ChatRuntime.async_stream(opts, &stream_typed_events(model, messages, &1))
      end

      def model_id(%__MODULE__{} = model), do: ChatRuntime.model_id(model)
      def profile(%__MODULE__{} = model), do: ChatRuntime.profile(model)

      defoverridable model_name: 1,
                     should_stream?: 1,
                     should_stream?: 2,
                     invoke: 2,
                     invoke: 3,
                     async_invoke: 2,
                     async_invoke: 3,
                     async_batch: 2,
                     async_batch: 3,
                     stream: 2,
                     stream: 3,
                     async_stream: 2,
                     async_stream: 3,
                     stream_response: 2,
                     stream_response: 3,
                     async_stream_response: 2,
                     async_stream_response: 3,
                     stream_events: 2,
                     stream_events: 3,
                     async_stream_events: 2,
                     async_stream_events: 3,
                     stream_typed_events: 2,
                     stream_typed_events: 3,
                     async_stream_typed_events: 2,
                     async_stream_typed_events: 3,
                     model_id: 1,
                     profile: 1
    end
  end
end
