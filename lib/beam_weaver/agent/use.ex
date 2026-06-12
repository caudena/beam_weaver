defmodule BeamWeaver.Agent.Use do
  @moduledoc false

  def quoted do
    imports = BeamWeaver.Agent.DSL.imports()
    attribute_quotes = BeamWeaver.Agent.DSL.register_attribute_quotes()

    quote do
      @behaviour BeamWeaver.Agent

      import BeamWeaver.Agent, only: unquote(imports)

      unquote_splicing(attribute_quotes)

      @before_compile BeamWeaver.Agent

      @impl BeamWeaver.Agent
      def checkpointer, do: nil

      @impl BeamWeaver.Agent
      def store, do: nil

      def start_link(opts \\ []) do
        BeamWeaver.Agent.Server.start_link(__MODULE__, opts)
      end

      def child_spec(opts) do
        %{
          id: Keyword.get(opts, :id, __MODULE__),
          start: {__MODULE__, :start_link, [opts]},
          restart: :temporary,
          type: :worker
        }
      end

      def invoke(input, opts \\ []) do
        BeamWeaver.Agent.invoke(__MODULE__, input, opts)
      end

      def async_invoke(input, opts \\ []) do
        BeamWeaver.Agent.async_invoke(__MODULE__, input, opts)
      end

      def stream_events(input, opts \\ []) do
        BeamWeaver.Agent.stream_events(__MODULE__, input, opts)
      end

      def resume(resume, opts \\ []) do
        BeamWeaver.Agent.resume(__MODULE__, resume, opts)
      end

      def resume_review(review_or_decisions, opts \\ []) do
        BeamWeaver.Agent.resume_review(__MODULE__, review_or_decisions, opts)
      end

      def get_state(opts \\ []) do
        BeamWeaver.Agent.get_state(__MODULE__, opts)
      end

      defoverridable checkpointer: 0,
                     store: 0
    end
  end
end
