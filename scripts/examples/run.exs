# Runs the live examples against real providers.
#
#   mix examples.live                          every provider with a key
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

  def main(argv) do
    {opts, _rest, invalid} =
      OptionParser.parse(argv,
        strict: [provider: :string, model: :string, only: :string, offline: :boolean, jobs: :integer, timeout: :integer]
      )

    if invalid != [], do: abort("unknown options: #{inspect(invalid)}")

    env = Map.merge(dotenv(), System.get_env())
    providers = select_providers(opts, env)
    jobs = jobs(manifest(), providers, opts)

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
      |> Enum.map(fn {:ok, result} -> print_result(result) end)

    print_table(results)
    if Enum.any?(results, &(&1.status != :pass)), do: System.halt(1)
  end

  defp manifest do
    @root |> Path.join("scripts/examples/manifest.exs") |> Code.eval_file() |> elem(0) |> Keyword.fetch!(:scripts)
  end

  # `{provider, model}` for each selected provider with a key.
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

    for {name, config} <- @providers,
        name in wanted,
        Enum.any?(config[:keys], &present?(env[&1])),
        do: {name, Map.get(model_override, name, config[:model])}
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
        if opts[:offline], do: [%{script: script, provider: :offline, model: nil, args: []}], else: []

      :live ->
        for {name, model} <- providers, model, do: %{script: script, provider: name, model: model, args: args}

      {:pinned, provider} ->
        if provider in provider_names, do: [%{script: script, provider: provider, model: nil, args: args}], else: []
    end
  end

  # A provider that is briefly over capacity (an HTTP 429 or 5xx error marked
  # retryable) says nothing about the example, so such a run gets one more try
  # after a pause. Failures of the example itself, such as a skipped tool,
  # never do.
  defp run(job, env, timeout) do
    case run_once(job, env, timeout) do
      %{status: :fail, output: output} = result ->
        if transient_provider_error?(output) do
          Process.sleep(@retry_pause_ms)
          job |> run_once(env, timeout) |> Map.put(:retried, true)
        else
          result
        end

      result ->
        result
    end
  end

  defp transient_provider_error?(output),
    do: output =~ "retryable: true" and Regex.match?(~r/status: (429|500|502|503|504|529)\b/, output)

  defp run_once(job, env, timeout) do
    log = Path.join([@logs, to_string(job.provider), String.replace(job.script, "/", "__") <> ".log"])
    File.mkdir_p!(Path.dirname(log))

    script_env =
      env
      |> Map.take(Enum.flat_map(@providers, fn {_name, config} -> config[:keys] end) ++ ["BEAM_WEAVER_POSTGRES_URL"])
      |> then(&if(job.model, do: Map.put(&1, "BEAM_WEAVER_EXAMPLES_MODEL", job.model), else: &1))
      |> Map.put_new("LANG", env["LANG"] || "en_US.UTF-8")
      |> Enum.map(fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)

    started = System.monotonic_time(:millisecond)

    port =
      Port.open({:spawn_executable, System.find_executable("mix")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["run", "--no-compile", "--no-deps-check", job.script | job.args],
        cd: String.to_charlist(@root),
        env: script_env
      ])

    {status, output} = collect(port, [], System.monotonic_time(:millisecond) + timeout)
    File.write!(log, output)
    Map.merge(job, %{status: status, ms: System.monotonic_time(:millisecond) - started, log: log, output: output})
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

BeamWeaver.Examples.LiveRunner.main(System.argv())
