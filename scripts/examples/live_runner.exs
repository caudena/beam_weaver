# Runs the live examples against real providers.
#
#   mix examples.live                          every provider; all keys required
#   mix examples.live --provider openai,zai    only these providers
#   mix examples.live --model anthropic:claude-sonnet-4-6
#   mix examples.live --only deepagents/       scripts whose path contains this
#   mix examples.live --offline                also run the offline scripts
#   mix examples.live --jobs 2 --timeout 600   concurrency and per-script seconds
#
# Keys come from the environment and from `.env` in the project root (KEY=value
# lines). Their values are passed to the scripts and never printed. Each script
# runs in its own `mix run` process; logs go to _build/examples_live/.
defmodule BeamWeaver.Examples.LiveRunner do
  @root Path.expand("../..", __DIR__)
  @logs Path.join(@root, "_build/examples_live")

  @retry_pause_ms 15_000

  @providers [
    openai: [keys: ["OPENAI_API_KEY"], model: "openai:gpt-5.4-mini"],
    anthropic: [keys: ["ANTHROPIC_API_KEY"], model: "anthropic:claude-haiku-4-5"],
    google: [keys: ["GOOGLE_API_KEY", "GEMINI_API_KEY"], model: "google:gemini-3.5-flash"],
    xai: [keys: ["XAI_API_KEY"], model: "xai:grok-4.3"],
    moonshot: [keys: ["MOONSHOT_API_KEY", "KIMI_API_KEY"], model: "moonshot:kimi-k2.6"],
    zai: [keys: ["ZAI_API_KEY"], model: "zai:glm-5.3-flash"],
    deepseek: [keys: ["DEEPSEEK_API_KEY"], model: "deepseek:deepseek-flash"],
    typesafe: [keys: ["TYPESAFE_API_KEY", "TYPESAFE_API"], model: nil]
  ]

  def provider_defaults, do: @providers

  def verify_job(job, env, timeout), do: run(job, env, timeout)

  def main(argv) do
    {opts, _rest, invalid} =
      OptionParser.parse(argv,
        strict: [provider: :string, model: :string, only: :string, offline: :boolean, jobs: :integer, timeout: :integer]
      )

    if invalid != [], do: abort("unknown options: #{inspect(invalid)}")

    env = Map.merge(dotenv(), System.get_env())
    providers = select_providers(opts, env)
    run_dir = Path.join([@logs, "runs", "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"])
    File.mkdir_p!(run_dir)
    jobs = jobs(manifest(), providers, opts) |> Enum.map(&Map.put(&1, :log_dir, run_dir))

    if jobs == [], do: abort("nothing to run (keys found for: #{Enum.map_join(providers, ", ", &elem(&1, 0))})")

    IO.puts(
      "Providers: #{Enum.map_join(providers, ", ", fn {name, model} -> "#{name} (#{model || "pinned scripts"})" end)}"
    )

    IO.puts("Running #{length(jobs)} scripts, #{opts[:jobs] || 4} at a time.\n")
    {_output, 0} = System.cmd("mix", ["compile"], cd: @root, into: IO.stream())

    results =
      jobs
      |> Task.async_stream(&run(&1, env, Keyword.get(opts, :timeout, 300) * 1_000),
        max_concurrency: Keyword.get(opts, :jobs, 4),
        timeout: :infinity,
        ordered: false
      )
      |> Enum.reduce([], fn {:ok, result}, results ->
        results = results ++ [print_result(result)]

        report = %{
          results: Enum.map(results, &Map.delete(&1, :output)),
          totals: Enum.frequencies_by(results, & &1.status)
        }

        File.write!(Path.join(run_dir, "report.json"), JSON.encode!(report))
        results
      end)

    print_table(results)
    IO.puts("Report: #{Path.join(run_dir, "report.json")}")
    if Enum.any?(results, &(&1.status != :pass)), do: System.halt(1)
  end

  defp manifest do
    @root |> Path.join("scripts/examples/manifest.exs") |> Code.eval_file() |> elem(0) |> Keyword.fetch!(:scripts)
  end

  # `{provider, model}` for each selected provider; missing keys fail selection.
  defp select_providers(opts, env) do
    wanted =
      case opts[:provider] do
        nil -> Keyword.keys(@providers)
        list -> list |> String.split(",", trim: true) |> Enum.map(&provider!/1)
      end

    model_override =
      case opts[:model] do
        nil -> %{}
        model -> %{provider!(model |> String.split(":", parts: 2) |> hd()) => model}
      end

    wanted = if map_size(model_override) > 0 and is_nil(opts[:provider]), do: Map.keys(model_override), else: wanted

    missing =
      for {name, config} <- @providers, name in wanted, not Enum.any?(config[:keys], &present?(env[&1])), do: name

    if missing != [], do: abort("Missing credentials for requested providers: #{Enum.join(missing, ", ")}")

    for {name, config} <- @providers, name in wanted, do: {name, Map.get(model_override, name, config[:model])}
  end

  defp jobs(manifest, providers, opts) do
    provider_names = Keyword.keys(providers)

    jobs =
      for {script, script_opts} <- manifest,
          job <- jobs_for(script, script_opts, providers, provider_names, opts),
          do: job

    case opts[:only] do
      nil -> jobs
      only -> Enum.filter(jobs, &String.contains?(&1.script, only))
    end
  end

  defp jobs_for(script, script_opts, providers, provider_names, opts) do
    args = Keyword.get(script_opts, :args, [])

    case script_opts[:run] do
      :offline ->
        offline_jobs(script, opts[:offline])

      :live ->
        for {name, model} <- providers, model, do: %{script: script, provider: name, model: model, args: args}

      {:pinned, provider} ->
        for ^provider <- provider_names, do: %{script: script, provider: provider, model: nil, args: args}
    end
  end

  defp offline_jobs(script, true), do: [%{script: script, provider: :offline, model: nil, args: []}]
  defp offline_jobs(_script, _offline), do: []

  # A provider that is briefly over capacity or unreachable (a retryable
  # rate limit, server error, lost connection or timeout) says nothing about
  # the example, so such a run gets one more try after a pause. Failures of
  # the example itself, such as a skipped tool, never do.
  defp run(job, env, timeout) do
    case run_once(job, env, timeout) do
      %{status: :fail, output: output} = result ->
        if transient_provider_error?(output) do
          Process.sleep(@retry_pause_ms)
          retried = run_once(job, env, timeout)

          retried
          |> Map.put(:retried, true)
          |> Map.put(:attempts, Enum.map([result, retried], &Map.take(&1, [:status, :ms, :log, :evidence])))
        else
          result
        end

      result ->
        result
    end
  end

  defp transient_provider_error?(output),
    do: output =~ "retryable: true" and Regex.match?(~r/type: :(rate_limit|server_error|connection|timeout)\b/, output)

  defp run_once(job, env, timeout) do
    directory =
      Map.get_lazy(job, :log_dir, fn ->
        Path.join([@logs, "runs", "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"])
      end)

    attempt = System.unique_integer([:positive])
    log = Path.join([directory, to_string(job.provider), String.replace(job.script, "/", "__") <> "-#{attempt}.log"])
    File.mkdir_p!(Path.dirname(log))

    scratch = Path.join(System.tmp_dir!(), "beam_weaver_example_#{System.pid()}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(scratch)

    spec =
      Keyword.fetch!(Code.eval_file(Path.join(@root, "scripts/examples/manifest.exs")) |> elem(0), :scripts)
      |> List.keyfind(job.script, 0)
      |> elem(1)

    required = if job.provider == :offline, do: [], else: Keyword.get(spec, :requires, [job.provider])
    evidence_path = log <> ".evidence.json"
    request_path = log <> ".request.etf"
    File.write!(request_path, :erlang.term_to_binary(Map.put(job, :required_providers, required)))

    script_env =
      env
      |> Map.take(Enum.flat_map(@providers, fn {_name, config} -> config[:keys] end) ++ ["BEAM_WEAVER_POSTGRES_URL"])
      |> then(&if(job.model, do: Map.put(&1, "BEAM_WEAVER_EXAMPLES_MODEL", job.model), else: &1))
      |> Map.put("TMPDIR", scratch)
      |> Map.put_new("LANG", env["LANG"] || "en_US.UTF-8")
      |> Enum.map(fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)

    started = System.monotonic_time(:millisecond)

    port =
      Port.open({:spawn_executable, System.find_executable("mix")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [
          "run",
          "--no-compile",
          "--no-deps-check",
          "scripts/examples/verify_worker.exs",
          request_path,
          evidence_path
        ],
        cd: String.to_charlist(@root),
        env: script_env
      ])

    {status, output} = collect(port, [], System.monotonic_time(:millisecond) + timeout)

    output =
      Enum.reduce(@providers, output, fn {_provider, config}, acc ->
        Enum.reduce(config[:keys], acc, fn key, text ->
          value = env[key]
          if is_binary(value) and byte_size(value) > 5, do: String.replace(text, value, "[REDACTED]"), else: text
        end)
      end)

    File.write!(log, output)
    File.rm_rf!(scratch)
    evidence = if File.exists?(evidence_path), do: evidence_path |> File.read!() |> JSON.decode!()
    status = if status == :pass and is_nil(evidence), do: :fail, else: status

    Map.merge(job, %{
      status: status,
      ms: System.monotonic_time(:millisecond) - started,
      log: log,
      evidence: evidence,
      output: output
    })
  end

  defp collect(port, acc, deadline) do
    receive do
      {^port, {:data, data}} -> collect(port, [acc | data], deadline)
      {^port, {:exit_status, 0}} -> {:pass, IO.iodata_to_binary(acc)}
      {^port, {:exit_status, _code}} -> {:fail, IO.iodata_to_binary(acc)}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        with {:os_pid, os_pid} <- Port.info(port, :os_pid), do: System.cmd("kill", ["-9", to_string(os_pid)])
        {:timeout, IO.iodata_to_binary(acc)}
    end
  end

  defp print_result(result) do
    label = result.status |> to_string() |> String.upcase() |> String.pad_trailing(7)
    retried = if Map.get(result, :retried), do: ", retried after a provider capacity error", else: ""

    IO.puts(
      "#{label} #{String.pad_trailing(to_string(result.provider), 9)} #{result.script} (#{seconds(result.ms)}#{retried})"
    )

    if result.status != :pass do
      result.output |> String.split("\n") |> Enum.take(-12) |> Enum.each(&IO.puts("        | " <> &1))
      IO.puts("        log: #{Path.relative_to(result.log, @root)}")
    end

    result
  end

  defp print_table(results) do
    providers = results |> Enum.map(& &1.provider) |> Enum.uniq() |> Enum.sort()
    scripts = results |> Enum.map(& &1.script) |> Enum.uniq() |> Enum.sort()
    by_key = Map.new(results, &{{&1.script, &1.provider}, &1})
    width = scripts |> Enum.map(&String.length/1) |> Enum.max()

    IO.puts(
      "\n" <>
        String.pad_trailing("script", width) <>
        Enum.map_join(providers, "", &("  " <> String.pad_trailing(to_string(&1), 9)))
    )

    for script <- scripts do
      cells =
        Enum.map_join(providers, "", fn provider ->
          cell =
            case by_key[{script, provider}] do
              nil -> "-"
              %{status: :pass, ms: ms} -> "ok #{seconds(ms)}"
              %{status: status} -> to_string(status)
            end

          "  " <> String.pad_trailing(cell, 9)
        end)

      IO.puts(String.pad_trailing(script, width) <> cells)
    end

    counts = Enum.frequencies_by(results, & &1.status)
    IO.puts("\n#{counts[:pass] || 0} passed, #{counts[:fail] || 0} failed, #{counts[:timeout] || 0} timed out")
  end

  defp seconds(ms), do: "#{Float.round(ms / 1_000, 1)}s"

  defp dotenv do
    path = Path.join(@root, ".env")

    if File.exists?(path) do
      for line <- File.stream!(path),
          line = String.trim(line),
          line != "" and not String.starts_with?(line, "#"),
          [key, value] <- [String.split(String.replace_prefix(line, "export ", ""), "=", parts: 2)],
          into: %{},
          do: {String.trim(key), value |> String.trim() |> String.trim("\"") |> String.trim("'")}
    else
      %{}
    end
  end

  defp provider!(name) do
    Enum.find(Keyword.keys(@providers), &(Atom.to_string(&1) == name)) ||
      abort("unknown provider #{inspect(name)}; known: #{Enum.map_join(@providers, ", ", &elem(&1, 0))}")
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp abort(message) do
    IO.puts(:stderr, message)
    System.halt(1)
  end
end
