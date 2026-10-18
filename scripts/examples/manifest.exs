# How each script in examples/ runs. `mix test` compile-checks every script
# and runs the offline ones; `mix examples.live` runs the live ones against
# real providers (see scripts/examples/run.exs).
#
#   run: :offline          no model or network calls
#   run: :live             any provider, picked with BEAM_WEAVER_EXAMPLES_MODEL
#   run: {:pinned, p}      one provider only (it uses provider-specific features)
#   tools: true            a live run must call tools; `false` says why not
#   args: [...]            extra script arguments for live runs
#   offline_args: [...]    arguments for an offline run of a live script
#
# Support files that other scripts load are listed under `support:`.
[
  support: [
    "examples/support.exs",
    "examples/deepagents/support/support.exs",
    "examples/typesafe_routing_prompts.exs"
  ],
  scripts: [
    {"examples/async_subagent_protocol_client.exs", run: :offline, tools: false},
    {"examples/basic_graph.exs", run: :offline, tools: false},
    {"examples/branching_waiting_graph.exs", run: :offline, tools: false},
    {"examples/durable_interrupt_resume_graph.exs", run: :offline, tools: false},
    {"examples/interpreter_adapter.exs", run: :offline, tools: false},
    {"examples/openai_apply_patch_tool.exs", run: :offline, tools: false},
    {"examples/openai_json_http_error.exs", run: :offline, tools: false},
    {"examples/research_pipeline_graph.exs", run: :offline, tools: false},
    {"examples/retrieval_indexing_agent.exs", run: :offline, tools: false},
    {"examples/sandbox_provider_registry.exs", run: :offline, tools: false},
    {"examples/streaming_redaction.exs", run: :offline, tools: false},
    {"examples/streaming_tool_call_chunks.exs", run: :offline, tools: false},
    {"examples/openai_responses_tool_roundtrip.exs",
     run: {:pinned, :openai}, tools: true, args: ["--live", "gpt-5.4-mini"], offline_args: []},
    {"examples/typesafe_dynamic_routing.exs", run: {:pinned, :typesafe}, tools: true, offline_args: ["--offline"]},
    {"examples/anthropic_opus55_compaction.exs", run: {:pinned, :anthropic}, tools: false},
    {"examples/deepseek.exs", run: {:pinned, :deepseek}, tools: false},
    {"examples/auto_mode_agent.exs", run: {:pinned, :openai}, tools: true},
    {"examples/openai_gpt6_controls.exs", run: {:pinned, :openai}, tools: false},
    {"examples/zai_media.exs", run: {:pinned, :zai}, tools: false},
    {"examples/chat_model.exs", run: :live, tools: false},
    {"examples/prompt_caching.exs", run: :live, tools: false},
    {"examples/deep_agent_composition.exs", run: :live, tools: true},
    {"examples/file_memory.exs", run: :live, tools: true, args: ["--reset"]},
    {"examples/hitl_agent.exs", run: :live, tools: true},
    {"examples/hitl_per_call_agent.exs", run: :live, tools: true},
    {"examples/long_term_memory.exs", run: :live, tools: true},
    {"examples/react_agent.exs", run: :live, tools: true},
    {"examples/streaming_agent.exs", run: :live, tools: true},
    {"examples/structured_output_agent.exs", run: :live, tools: true},
    {"examples/subagent_supervisor.exs", run: :live, tools: true},
    {"examples/tool_injected_args.exs", run: :live, tools: true},
    {"examples/deepagents/async_subagent_server.exs", run: :live, tools: true},
    {"examples/deepagents/better_harness.exs", run: :live, tools: true},
    {"examples/deepagents/content_builder_agent.exs", run: :live, tools: true},
    {"examples/deepagents/deep_research.exs", run: :live, tools: true},
    {"examples/deepagents/deploy_coding_agent.exs", run: :live, tools: true},
    {"examples/deepagents/deploy_content_writer.exs", run: :live, tools: true},
    {"examples/deepagents/deploy_gtm_agent.exs", run: :live, tools: true},
    {"examples/deepagents/deploy_mcp_docs_agent.exs", run: :live, tools: true},
    {"examples/deepagents/downloading_agents.exs", run: :live, tools: true},
    {"examples/deepagents/llm_wiki.exs", run: :live, tools: true},
    {"examples/deepagents/nvidia_deep_agent.exs", run: :live, tools: true},
    {"examples/deepagents/ralph_mode.exs", run: :live, tools: true},
    {"examples/deepagents/repl_swarm.exs", run: :live, tools: true},
    {"examples/deepagents/rlm_agent.exs", run: :live, tools: true},
    {"examples/deepagents/text_to_sql_agent.exs", run: :live, tools: true}
  ]
]
