defmodule BeamWeaver.Docs.APIInventory do
  @moduledoc false

  # Feature ownership is explicit. A module can be taught through its feature
  # guide without every result struct being named in the narrative. Keep those
  # mappings distinct from literal references and member-level documentation.
  @feature_guides %{
    "Agents" => ~w(agents structured_output),
    "Testing" => ~w(testing),
    "Models and Messages" => ~w(models messages profiles configuration),
    "Tools" => ~w(tools runtime_context),
    "Middleware" => ~w(middleware builtin_middleware guardrails),
    "Streaming" => ~w(streaming),
    "Memory and Context" => ~w(short_term_memory long_term_memory memory_files context_management),
    "Oversight and Safety" => ~w(human_in_the_loop guardrails),
    "Deep Agents" => ~w(deep_agents filesystem skills subagents sandboxes profiles),
    "Graphs" => ~w(graphs graph_state workflow_patterns subgraphs checkpoints durable_execution),
    "Retrieval" => ~w(retrieval),
    "Production" => ~w(going_to_production configuration tracing storage caching rate_limiting compaction_engine),
    "Providers" => ~w(providers models testing),
    "OpenAI" => ~w(providers/openai),
    "Anthropic" => ~w(providers/anthropic),
    "Google Gemini" => ~w(providers/google),
    "DeepSeek" => ~w(providers/deepseek),
    "Moonshot (Kimi)" => ~w(providers/moonshot),
    "xAI" => ~w(providers/xai),
    "Z.ai" => ~w(providers/zai),
    "TypeSafe" => ~w(providers/typesafe)
  }

  def build do
    Application.load(:beam_weaver)
    groups = Code.eval_file(Path.join(__DIR__, "module_groups.exs")) |> elem(0)

    guides =
      Path.wildcard(Path.join(__DIR__, "../../docs/**/*.md")) |> Map.new(&{Path.relative_to_cwd(&1), File.read!(&1)})

    for module <- Application.spec(:beam_weaver, :modules) |> Enum.sort(),
        {:docs_v1, _, _, _, module_doc, _, entries} <- [Code.fetch_docs(module)],
        module_doc != :hidden do
      group =
        Enum.find_value(groups, fn {group, patterns} ->
          if Enum.any?(patterns, fn
               %Regex{} = regex -> Regex.match?(regex, inspect(module))
               name -> name == module
             end),
             do: to_string(group)
        end)

      refs = for {page, text} <- guides, String.contains?(text, inspect(module)), do: page

      feature_guides =
        Map.fetch!(@feature_guides, group)
        |> Enum.map(fn name ->
          page = "docs/#{name}.md"
          unless Map.has_key?(guides, page), do: raise("Missing feature guide: #{page}")
          page
        end)

      members =
        for {{kind, name, arity}, _, signatures, doc, metadata} <- entries,
            doc != :hidden,
            do: %{
              kind: kind,
              name: name,
              arity: arity,
              signatures: signatures,
              defaults: metadata[:defaults] || 0,
              documentation: if(is_map(doc), do: "documented", else: "signature_only")
            }

      %{
        module: inspect(module),
        group: group,
        feature_guides: feature_guides,
        guides: refs,
        module_documentation: is_map(module_doc),
        members: members
      }
    end
  end
end
