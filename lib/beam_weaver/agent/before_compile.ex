defmodule BeamWeaver.Agent.BeforeCompile do
  @moduledoc false

  alias BeamWeaver.Agent.DSL

  def compile(env) do
    attrs = DSL.collect_attrs(env.module)

    DSL.validate_static_agent!(env, attrs)
    DSL.reject_in_memory_adapters!(env, attrs)

    {storage_quotes, attrs} = BeamWeaver.Graph.DSL.storage_callbacks(env, attrs)

    context_schema_quote = DSL.schema_quote(attrs.context_schema, attrs.context_schema_entries)
    model_opts_quote = DSL.model_opts_quote(attrs.model_options, attrs.model_opts)
    spec_quote = DSL.spec_quote(%{attrs | context_schema: context_schema_quote, model_opts: model_opts_quote})

    quote do
      unquote(spec_quote)
      unquote(DSL.graph_quotes())
      unquote_splicing(storage_quotes)
    end
  end
end
