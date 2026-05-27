import Config

config :beam_weaver,
  openai: [],
  anthropic: [],
  google: [],
  xai: [],
  langsmith: [
    endpoint: "https://api.smith.langchain.com",
    project: "default"
  ],
  tracing: [],
  evals: [
    provider_api_keys: [],
    deep_agents_harbor?: false,
    external_sandbox?: false
  ],
  execution: [
    delta_max_supersteps_since_snapshot: 5_000
  ],
  examples: [
    deep_agents_live?: false,
    deep_agents_model: "openai:gpt-5.4-mini"
  ],
  test: []

env_config = Path.join(__DIR__, "#{config_env()}.exs")

if File.exists?(env_config) do
  import_config "#{config_env()}.exs"
end
