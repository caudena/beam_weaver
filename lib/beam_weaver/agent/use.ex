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

      def invoke(input, opts \\ []) do
        BeamWeaver.Agent.invoke(__MODULE__, input, opts)
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
    end
  end
end
