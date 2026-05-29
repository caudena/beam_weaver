ExUnit.start(exclude: [postgres: true])

Code.require_file("../support/config_helper.exs", __DIR__)
Code.require_file("../support/conformance/subject.exs", __DIR__)

Path.wildcard(Path.expand("../support/conformance/*.exs", __DIR__))
|> Enum.reject(&String.ends_with?(&1, "/subject.exs"))
|> Enum.sort()
|> Enum.each(&Code.require_file/1)

Code.require_file("../support/live_postgres.exs", __DIR__)

Path.wildcard(Path.expand("../support/deep_agents/*.exs", __DIR__))
|> Enum.sort()
|> Enum.each(&Code.require_file/1)
