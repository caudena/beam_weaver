import Config

config :beam_weaver,
  openai: [],
  anthropic: [],
  deepseek: [],
  google: [],
  typesafe: [],
  xai: [],
  zai: [],
  tracing: [],
  execution: [
    delta_max_supersteps_since_snapshot: 5_000
  ],
  test: []

env_config = Path.join(__DIR__, "#{config_env()}.exs")

if File.exists?(env_config) do
  import_config "#{config_env()}.exs"
end
