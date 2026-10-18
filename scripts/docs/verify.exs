Code.require_file("services.exs", __DIR__)
Code.require_file("consumer.exs", __DIR__)
Code.require_file("api_inventory.exs", __DIR__)
Code.require_file("../examples/live_runner.exs", __DIR__)

defmodule BeamWeaver.Docs.Verify do
  @moduledoc false
  alias BeamWeaver.TestSupport.DocSnippets, as: Snippets
  alias BeamWeaver.Examples.LiveRunner
  @root Path.expand("../..", __DIR__)

  def main(argv) do
    {opts, rest, invalid} =
      OptionParser.parse(argv,
        strict: [
          all: :boolean,
          provider: :string,
          model: :string,
          service: :string,
          scenario: :string,
          only: :string,
          timeout: :integer,
          scripts: :boolean,
          package: :boolean
        ]
      )

    if invalid != [] or rest != [], do: Mix.raise("Unknown docs.verify arguments: #{inspect(invalid ++ rest)}")
    Snippets.configure_live_providers!()
    selected = csv(opts[:provider])
    known = Enum.map(Snippets.provider_keys(), fn {p, _} -> to_string(p) end)
    if selected -- known != [], do: Mix.raise("Unknown providers: #{inspect(selected -- known)}")

    services =
      if opts[:all],
        do: ~w(live postgres docker),
        else: csv(opts[:service]) ++ if(selected == [] and is_nil(opts[:model]), do: [], else: ["live"])

    if services -- ~w(live postgres docker) != [], do: Mix.raise("Unknown services")
    report_root = Path.join(@root, "_build/docs_verify")

    report_dir =
      Path.join([report_root, "runs", "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"])

    File.mkdir_p!(report_dir)

    File.write!(
      Path.join(report_dir, "api_inventory.json"),
      BeamWeaver.JSON.encode!(BeamWeaver.Docs.APIInventory.build())
    )

    jobs =
      for page <- Snippets.all_pages(),
          matches?(Snippets.slug(page), opts[:only]),
          {scenario, blocks} <- Enum.group_by(Snippets.blocks(page), & &1.scenario),
          matches?(Snippets.slug(page) <> "/" <> scenario, opts[:scenario]),
          is_nil(opts[:model]) or Enum.any?(blocks, &String.contains?(&1.code, opts[:model])),
          requirements = Enum.uniq(Enum.flat_map(blocks, & &1.requirements)),
          providers = Enum.uniq(Enum.flat_map(blocks, & &1.providers)),
          selected == [] or providers == [] or Enum.all?(providers, &(&1 in selected)),
          opts[:all] == true or Enum.all?(requirements, &(&1 in services)),
          do: %{page: page, scenario: scenario, blocks: blocks, requirements: requirements, providers: providers}

    full? = opts[:all] == true and Enum.all?([:only, :scenario, :model, :provider], &is_nil(opts[&1]))
    script_jobs = if full? or opts[:scripts] == true, do: scripts(opts, selected), else: []

    if jobs == [] and script_jobs == [] and not opts[:package],
      do: Mix.raise("No matching scenarios; nothing was verified")

    package? =
      opts[:package] == true or
        (opts[:all] == true and Enum.any?(jobs, fn job -> Enum.any?(job.blocks, &(&1.mode == "mix")) end))

    package = if package?, do: BeamWeaver.Docs.Consumer.run(report_dir)
    package_verified? = package && package.status == "pass"

    report = %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      selection: Map.new(opts),
      coverage: if(full?, do: "all", else: "selected"),
      examples: [],
      package: package,
      public_hex_installation: %{
        status: "pending",
        reason: "Release-targeted Hex installation must be verified after 1.0.0 publication"
      }
    }

    write_report(report, report_dir, report_root)

    report =
      Enum.reduce(jobs, report, fn job, report ->
        missing = Snippets.missing_credentials(job.providers)

        records =
          if missing == [] do
            case BeamWeaver.Docs.Services.with_services(job.requirements, fn env ->
                   run(
                     Map.put(job, :package_verified, package_verified?),
                     services,
                     report_dir,
                     (opts[:timeout] || 300) * 1_000,
                     env
                   )
                 end) do
              {:blocked, reason} -> blocked(job, reason)
              records -> records
            end
          else
            blocked(job, "Missing credentials: #{Enum.join(missing, ", ")}")
          end

        failures = Enum.count(records, &(&1.status != "pass"))

        Mix.shell().info(
          "#{Snippets.slug(job.page)}/#{job.scenario}: #{length(records) - failures} passed, #{failures} incomplete"
        )

        report = %{report | examples: report.examples ++ records}
        write_report(report, report_dir, report_root)
        report
      end)

    report =
      Enum.reduce(script_jobs, report, fn job, report ->
        missing = if job.provider == :offline, do: [], else: Snippets.missing_credentials([job.provider])

        result =
          if missing == [] do
            run = LiveRunner.verify_job(job, System.get_env(), (opts[:timeout] || 300) * 1_000)

            %{
              file: job.script,
              line: 1,
              status: to_string(run.status),
              provider: job.provider,
              model: job.model,
              method: "script process",
              log: run.log,
              code: File.read!(Path.join(@root, job.script))
            }
          else
            %{file: job.script, line: 1, status: "blocked", reason: "Missing credentials: #{Enum.join(missing, ", ")}"}
          end

        Mix.shell().info("#{job.script}: #{result.status}")
        report = %{report | examples: report.examples ++ [result]}
        write_report(report, report_dir, report_root)
        report
      end)

    report =
      if full? or package?,
        do: %{report | public_hex_installation: BeamWeaver.Docs.Consumer.verify_public(report_dir)},
        else: report

    write_report(report, report_dir, report_root)
    Mix.shell().info("Report: #{Path.join(report_dir, "report.json")}")

    if (package != nil and package.status != "pass") or Enum.any?(report.examples, &(&1.status != "pass")),
      do: Mix.raise("Documentation verification is incomplete; see report.json")

    if full? and report.public_hex_installation.status != "pass",
      do:
        Mix.raise(
          "Executable examples passed; public Hex installation is still #{report.public_hex_installation.status}"
        )
  end

  def scripts(opts, selected) do
    manifest = Code.eval_file(Path.join(@root, "scripts/examples/manifest.exs")) |> elem(0)
    defaults = LiveRunner.provider_defaults()

    for {script, spec} <- manifest[:scripts],
        matches?(script, opts[:only]),
        provider = script_provider(spec, opts, selected),
        not is_nil(provider),
        provider == :offline or selected == [] or to_string(provider) in selected do
      model = if spec[:run] == :live, do: opts[:model] || defaults[provider][:model]
      %{script: script, provider: provider, model: model, args: spec[:args] || []}
    end
  end

  defp script_provider(spec, opts, selected) do
    case spec[:run] do
      :offline ->
        :offline

      {:pinned, provider} ->
        provider

      :live ->
        defaults = LiveRunner.provider_defaults()

        requested =
          if opts[:model],
            do: opts[:model] |> String.split(":") |> hd(),
            else:
              Enum.find(selected, fn name ->
                Enum.any?(defaults, fn {provider, config} ->
                  to_string(provider) == name and not is_nil(config[:model])
                end)
              end) || if(selected == [], do: "openai")

        Enum.find_value(defaults, fn {provider, config} ->
          if to_string(provider) == requested and config[:model], do: provider
        end)
    end
  end

  defp write_report(report, directory, root) do
    report = Map.put(report, :totals, Enum.frequencies_by(report.examples, & &1.status))
    json = redact(BeamWeaver.JSON.encode!(report))
    File.write!(Path.join(directory, "report.json"), json)
    File.write!(Path.join(root, "report.json"), json)
  end

  defp run(job, services, report_dir, timeout, env) do
    dir = Path.join(report_dir, Snippets.slug(job.page) <> "-" <> job.scenario)
    File.mkdir_p!(dir)
    request = Path.join(dir, "request.etf")
    result = Path.join(dir, "result.etf")
    File.write!(request, :erlang.term_to_binary(Map.put(job, :services, services)))
    paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))
    args = Enum.flat_map(paths, &["-pa", &1]) ++ ["scripts/docs/verify_worker.exs", request, result]
    executable = System.find_executable("elixir") || raise "Elixir executable not found"

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        cd: String.to_charlist(@root),
        env: Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
      ])

    {exit, output} = collect(port, [], System.monotonic_time(:millisecond) + timeout)
    File.write!(Path.join(dir, "output.log"), redact(output))

    case exit do
      0 ->
        if File.exists?(result),
          do: result |> File.read!() |> :erlang.binary_to_term(),
          else: blocked(job, "Worker exited without an execution report")

      :timeout ->
        blocked(job, "Scenario timed out after #{div(timeout, 1000)} seconds")

      code ->
        blocked(job, "Worker exited #{code}; see #{Path.join(dir, "output.log")}")
    end
  end

  defp collect(port, output, deadline) do
    receive do
      {^port, {:data, data}} -> collect(port, [output, data], deadline)
      {^port, {:exit_status, status}} -> {status, IO.iodata_to_binary(output)}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        case Port.info(port, :os_pid) do
          {:os_pid, pid} -> System.cmd("kill", ["-9", to_string(pid)])
          nil -> :ok
        end

        {:timeout, IO.iodata_to_binary(output)}
    end
  end

  defp blocked(job, reason),
    do:
      Enum.map(
        job.blocks,
        &%{
          file: &1.file,
          line: &1.line,
          code: &1.code,
          scenario: &1.scenario,
          status: "blocked",
          reason: reason,
          requirements: &1.requirements,
          providers: &1.providers
        }
      )

  defp csv(nil), do: []
  defp csv(value), do: String.split(value, ",", trim: true)
  defp matches?(_value, nil), do: true
  defp matches?(value, filter), do: String.contains?(value, filter)

  defp redact(text) do
    Enum.reduce(Snippets.provider_keys(), text, fn {_provider, names}, text ->
      Enum.reduce(names, text, fn name, text ->
        case System.get_env(name) do
          value when is_binary(value) and byte_size(value) > 5 -> String.replace(text, value, "[REDACTED]")
          _ -> text
        end
      end)
    end)
  end
end
