# `assert_receive` returns as soon as the message arrives, so a generous default
# only slows down failing tests while keeping passing ones stable under load.
ExUnit.start(
  exclude: [docker: true, postgres: true, typesafe_live: true],
  assert_receive_timeout: 1_000
)

# Each test run gets its own temp directory, so suites running at the same time
# (several checkouts, or CI jobs on one machine) never share scratch paths such
# as the docs' workspace directories.
test_tmp_dir = Path.join(System.tmp_dir!(), "beam_weaver_test_#{System.pid()}")
File.mkdir_p!(test_tmp_dir)
System.put_env("TMPDIR", test_tmp_dir)
ExUnit.after_suite(fn _result -> File.rm_rf(test_tmp_dir) end)

Code.require_file("../support/typesafe.exs", __DIR__)
Code.require_file("../support/openai_decisions.exs", __DIR__)

Code.require_file("../support/config_helper.exs", __DIR__)
Code.require_file("../support/eventually.exs", __DIR__)
Code.require_file("../support/conformance/subject.exs", __DIR__)
Code.require_file("../support/provider_conformance.exs", __DIR__)

Path.wildcard(Path.expand("../support/conformance/*.exs", __DIR__))
|> Enum.reject(&String.ends_with?(&1, "/subject.exs"))
|> Enum.sort()
|> Enum.each(&Code.require_file/1)

Code.require_file("../support/live_postgres.exs", __DIR__)
Code.require_file("../support/live_sqlite.exs", __DIR__)
Code.require_file("../support/doc_snippets.exs", __DIR__)

Path.wildcard(Path.expand("../support/deep_agents/*.exs", __DIR__))
|> Enum.sort()
|> Enum.each(&Code.require_file/1)
