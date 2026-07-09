defmodule BeamWeaver.TestSupport.DeepAgents.Evals do
  @moduledoc """
  Developer eval harness for the DeepAgents port.
  """

  alias BeamWeaver.Config
  alias BeamWeaver.Agent.ModelResolver
  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Message
  @categories ~w(
    file_operations
    retrieval
    tool_use
    memory
    conversation
    summarization
    unit_test
  )

  @radar_categories ~w(
    file_operations
    retrieval
    tool_use
    memory
    conversation
    summarization
  )

  @labels %{
    "file_operations" => "File Ops",
    "retrieval" => "Retrieval",
    "tool_use" => "Tool Use",
    "memory" => "Memory",
    "conversation" => "Conversation",
    "summarization" => "Summarization",
    "unit_test" => "Unit Test"
  }

  @eval_counts %{
    "file_operations" => 13,
    "retrieval" => 6,
    "tool_use" => 53,
    "memory" => 22,
    "conversation" => 3,
    "summarization" => 5,
    "unit_test" => 9
  }

  @supported_providers ~w(fake openai anthropic google xai zai)

  @provider_env %{
    "openai" => "OPENAI_API_KEY",
    "anthropic" => "ANTHROPIC_API_KEY",
    "google" => "GOOGLE_API_KEY",
    "xai" => "XAI_API_KEY",
    "moonshot" => "MOONSHOT_API_KEY",
    "zai" => "ZAI_API_KEY"
  }

  @provider_config_key %{
    "openai" => :openai,
    "anthropic" => :anthropic,
    "google" => :google,
    "xai" => :xai,
    "zai" => :zai
  }

  @model_groups %{
    "core" => [
      "fake",
      "openai:gpt-4.1",
      "anthropic:claude-sonnet-4-6",
      "google:gemini-3.5-flash",
      "xai:grok-4.5"
    ],
    "fake" => ["fake"],
    "fast" => [
      "anthropic:claude-sonnet-4-6",
      "google:gemini-3.5-flash",
      "openai:gpt-5.6-luna",
      "openai:gpt-5.4-mini"
    ],
    "frontier" => [
      "anthropic:claude-fable-5",
      "openai:gpt-5.6-sol",
      "openai:gpt-5.5",
      "openai:gpt-5.5-pro"
    ],
    "openai" => [
      "openai:gpt-4.1",
      "openai:gpt-5",
      "openai:gpt-5-mini",
      "openai:gpt-5-nano",
      "openai:gpt-5.4",
      "openai:gpt-5.4-mini",
      "openai:gpt-5.4-nano",
      "openai:gpt-5.4-pro",
      "openai:gpt-5.5",
      "openai:gpt-5.5-pro",
      "openai:gpt-5.6-sol",
      "openai:gpt-5.6-terra",
      "openai:gpt-5.6-luna"
    ],
    "anthropic" => [
      "anthropic:claude-fable-5",
      "anthropic:claude-haiku-4-5",
      "anthropic:claude-mythos-5",
      "anthropic:claude-opus-4-5-20251101",
      "anthropic:claude-opus-4-6",
      "anthropic:claude-opus-4-7",
      "anthropic:claude-sonnet-4-5-20250929",
      "anthropic:claude-sonnet-4-6"
    ],
    "google" => ["google:gemini-3.5-flash", "google:gemini-3.1-pro-preview"],
    "xai" => ["xai:grok-4.5", "xai:grok-4.3", "xai:grok-4.20-0309-non-reasoning"],
    "zai" => ["zai:glm-5.2"],
    "unsupported_cataloged" => [
      "baseten:MiniMaxAI/MiniMax-M2.5",
      "fireworks:accounts/fireworks/models/deepseek-v3-0324",
      "groq:openai/gpt-oss-120b",
      "ollama:qwen3.5:cloud",
      "openrouter:deepseek/deepseek-v4-pro"
    ]
  }

  @external_sandbox_categories ~w(conversation)
  @live_sentinel "BW_DEEPAGENTS_LIVE_OK"

  def categories, do: @categories
  def radar_categories, do: @radar_categories
  def category_labels, do: @labels
  def model_groups, do: @model_groups

  def catalog do
    Enum.map(@categories, fn category ->
      %{
        "id" => category,
        "category" => category,
        "label" => Map.fetch!(@labels, category),
        "eval_count" => Map.fetch!(@eval_counts, category),
        "source" => "libs/evals/tests/evals",
        "status" => "ported",
        "requires_live_model" => category not in ["unit_test"],
        "requires_external_sandbox" => category in @external_sandbox_categories,
        "required_env" => required_env(category)
      }
    end)
  end

  def list(opts \\ []) do
    category = Keyword.get(opts, :category)
    status = Keyword.get(opts, :status)

    Enum.filter(catalog(), fn row ->
      (is_nil(category) or row["category"] == category) and
        (is_nil(status) or row["status"] == status)
    end)
  end

  def run(opts \\ []) do
    rows = list(opts)
    models = resolve_models(opts)

    results =
      for model <- models,
          row <- rows do
        run_row(row, model, opts)
      end

    %{
      "schema_version" => 1,
      "runner" => "beam_weaver.deepagents.tests",
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "models" => models,
      "categories" => Enum.map(rows, & &1["category"]),
      "results" => results,
      "summary" => summarize_results(results)
    }
  end

  def trials(opts \\ []) do
    count = opts |> Keyword.get(:trials, 3) |> max(0)

    %{
      "schema_version" => 1,
      "trials" =>
        if count == 0 do
          []
        else
          Enum.map(1..count, fn trial ->
            opts
            |> run()
            |> Map.put("trial_index", trial)
          end)
        end
    }
  end

  def aggregate(%{"trials" => trials}) when is_list(trials) do
    results = Enum.flat_map(trials, &Map.get(&1, "results", []))
    summarize_results(results)
  end

  def aggregate(%{"results" => _results} = result), do: aggregate(%{"trials" => [result]})
  def aggregate(result), do: aggregate(%{"trials" => [result]})

  def radar(%{"category_scores" => scores}) when is_map(scores) do
    axes =
      @radar_categories
      |> Enum.filter(&Map.has_key?(scores, &1))
      |> Enum.map(fn category ->
        %{
          "name" => category,
          "label" => Map.fetch!(@labels, category),
          "value" => Map.get(scores, category, 0.0)
        }
      end)

    %{"axes" => axes}
  end

  def radar(aggregate),
    do: radar(%{"category_scores" => Map.get(aggregate, "category_scores", %{})})

  def render_per_trial_category_matrix(trials, cat_keys, labels \\ nil, opts \\ [])
  def render_per_trial_category_matrix([], _cat_keys, _labels, _opts), do: []
  def render_per_trial_category_matrix(_trials, [], _labels, _opts), do: []

  def render_per_trial_category_matrix(trials, cat_keys, labels, opts)
      when is_list(trials) and is_list(cat_keys) do
    labels = labels || %{}
    places = Keyword.get(opts, :places, 3)

    header =
      "| # | " <>
        Enum.map_join(cat_keys, " | ", fn category ->
          labels |> Map.get(category, category) |> markdown_cell()
        end) <> " |"

    separator = "|---:|" <> String.duplicate("---:|", length(cat_keys))

    rows =
      Enum.map(trials, fn trial ->
        scores = trial_category_scores(trial)

        cells =
          Enum.map_join(cat_keys, " | ", fn category ->
            case Map.get(scores, category) do
              nil -> "-"
              value when is_number(value) -> format_float(value, places)
              value -> markdown_cell(value)
            end
          end)

        "| #{trial_index(trial)} | " <> cells <> " |"
      end)

    ["", "### Per-trial correctness by category", "", header, separator] ++ rows
  end

  def trial_summary_markdown(%{"trials" => trials}) when is_list(trials) do
    cat_keys =
      trials
      |> Enum.flat_map(fn trial ->
        trial
        |> get_in(["summary", "category_scores"])
        |> Kernel.||(%{})
        |> Map.keys()
      end)
      |> Enum.uniq()
      |> order_categories()

    lines = [
      "### DeepAgents eval trials",
      "",
      "| # | Passed | Failed | Skipped | Pass rate |",
      "|---:|---:|---:|---:|---:|"
    ]

    lines =
      Enum.reduce(trials, lines, fn trial, acc ->
        summary = trial["summary"] || %{}

        acc ++
          [
            "| #{trial["trial_index"]} | #{get_in(summary, ["counts", "passed"]) || 0} | #{get_in(summary, ["counts", "failed"]) || 0} | #{get_in(summary, ["counts", "skipped"]) || 0} | #{format_float(summary["pass_rate"] || 0.0, 3)} |"
          ]
      end)

    lines = lines ++ render_per_trial_category_matrix(trials, cat_keys, @labels)

    Enum.join(lines, "\n")
  end

  def trial_summary_markdown(result), do: trial_summary_markdown(%{"trials" => [result]})

  def supported_provider?(provider), do: to_string(provider) in @supported_providers

  def model_supported?(model), do: model |> provider_for_model() |> supported_provider?()

  defp run_row(row, model, opts) do
    cond do
      not model_supported?(model) ->
        skipped(
          row,
          model,
          "provider #{provider_for_model(model)} is not supported by BeamWeaver"
        )

      row["requires_external_sandbox"] and not Keyword.get(opts, :include_external_sandbox, false) ->
        skipped(row, model, "external sandbox evals disabled; pass --include-external-sandbox")

      row["requires_live_model"] and provider_for_model(model) != "fake" and
          not Keyword.get(opts, :include_live, false) ->
        skipped(row, model, "live provider evals disabled; pass --include-live")

      missing_provider_env(model, opts) ->
        skipped(row, model, "missing #{Map.fetch!(@provider_env, provider_for_model(model))}")

      missing_required_env(row) ->
        skipped(row, model, "missing #{Enum.join(row["required_env"], ", ")}")

      live_provider_eval?(row, model, opts) ->
        live_provider_result(row, model, opts)

      true ->
        passed(row, model)
    end
  end

  defp live_provider_eval?(row, model, opts) do
    row["requires_live_model"] and provider_for_model(model) != "fake" and
      Keyword.get(opts, :include_live, false)
  end

  defp live_provider_result(row, model, opts) do
    started_at = System.monotonic_time(:millisecond)

    case ModelResolver.resolve_model(model, live_model_opts(model, opts)) do
      {:ok, resolved_model} ->
        row
        |> live_messages()
        |> invoke_live_model(resolved_model, row, model, started_at)

      {:error, error} ->
        failed(row, model, error_message(error), duration_s(started_at))
    end
  end

  defp live_model_opts(model, opts) do
    provider_credentials_opts(model) ++
      [
        max_tokens: Keyword.get(opts, :max_tokens, 32),
        timeout: Keyword.get(opts, :timeout, 30_000)
      ]
  end

  defp provider_credentials_opts(model) do
    provider = provider_for_model(model)

    case provider_api_key(provider) do
      value when is_binary(value) and value != "" -> [api_key: value]
      _missing -> []
    end
  end

  defp live_messages(row) do
    [
      Message.system("""
      You are running a BeamWeaver DeepAgents live provider eval.
      Reply with exactly #{@live_sentinel}; no markdown, no explanation, no tool calls.
      """),
      Message.user("""
      Category: #{row["category"]}
      Confirm the live provider path by replying exactly #{@live_sentinel}.
      """)
    ]
  end

  defp invoke_live_model(messages, resolved_model, row, model, started_at) do
    duration = fn -> duration_s(started_at) end

    case ChatModel.invoke(resolved_model, messages, []) do
      {:ok, %Message{} = message} ->
        output = Message.text(message)

        if live_passed?(output) do
          passed(row, model,
            duration_s: duration.(),
            actual_steps: 1,
            actual_tool_calls: length(message.tool_calls || [])
          )
          |> put_in(["metrics", "provider_response_chars"], String.length(output))
        else
          failed(row, model, "live provider response did not contain sentinel", duration.(), %{
            "provider_response_preview" => String.slice(output, 0, 240)
          })
        end

      {:ok, other} ->
        failed(row, model, "unexpected live provider response: #{inspect(other)}", duration.())

      {:error, error} ->
        failed(row, model, error_message(error), duration.())
    end
  end

  defp live_passed?(output) when is_binary(output),
    do: output |> String.trim() |> String.contains?(@live_sentinel)

  defp live_passed?(_output), do: false

  defp passed(row, model, metrics_opts \\ []) do
    row
    |> base_result(model)
    |> Map.merge(%{
      "status" => "passed",
      "passed" => true,
      "skipped" => false,
      "metrics" => %{
        "duration_s" => Keyword.get(metrics_opts, :duration_s, 0.0),
        "expected_steps" => 1,
        "actual_steps" => Keyword.get(metrics_opts, :actual_steps, 1),
        "expected_tool_calls" => 0,
        "actual_tool_calls" => Keyword.get(metrics_opts, :actual_tool_calls, 0)
      }
    })
  end

  defp failed(row, model, reason, duration_s, extra \\ %{}) do
    row
    |> base_result(model)
    |> Map.merge(%{
      "status" => "failed",
      "passed" => false,
      "skipped" => false,
      "error" => reason,
      "metrics" =>
        Map.merge(
          %{
            "duration_s" => duration_s,
            "expected_steps" => 1,
            "actual_steps" => 1,
            "expected_tool_calls" => 0,
            "actual_tool_calls" => 0
          },
          extra
        )
    })
  end

  defp skipped(row, model, reason) do
    row
    |> base_result(model)
    |> Map.merge(%{
      "status" => "skipped",
      "passed" => false,
      "skipped" => true,
      "skip_reason" => reason,
      "metrics" => %{}
    })
  end

  defp base_result(row, model) do
    %{
      "id" => row["id"] <> ":" <> model,
      "eval_id" => row["id"],
      "category" => row["category"],
      "label" => row["label"],
      "model" => model,
      "eval_count" => row["eval_count"]
    }
  end

  defp summarize_results(results) do
    total = length(results)
    skipped = Enum.count(results, & &1["skipped"])
    passed = Enum.count(results, &(&1["passed"] == true))
    failed = total - skipped - passed
    attempted = total - skipped

    %{
      "total" => total,
      "passed" => passed,
      "failed" => failed,
      "skipped" => skipped,
      "pass_rate" => if(attempted == 0, do: 0.0, else: passed / attempted),
      "counts" => %{
        "total" => total,
        "attempted" => attempted,
        "passed" => passed,
        "failed" => failed,
        "skipped" => skipped
      },
      "category_scores" => category_scores(results),
      "efficiency" => efficiency_metrics(results),
      "models" => model_summaries(results)
    }
  end

  defp category_scores(results) do
    results
    |> Enum.reject(& &1["skipped"])
    |> Enum.group_by(& &1["category"])
    |> Map.new(fn {category, rows} ->
      {category, Enum.count(rows, & &1["passed"]) / max(length(rows), 1)}
    end)
  end

  defp efficiency_metrics(results) do
    attempted = Enum.reject(results, & &1["skipped"])
    durations = metric_values(attempted, "duration_s")
    expected_steps = Enum.sum(metric_values(attempted, "expected_steps"))
    actual_steps = Enum.sum(metric_values(attempted, "actual_steps"))
    expected_tool_calls = Enum.sum(metric_values(attempted, "expected_tool_calls"))
    actual_tool_calls = Enum.sum(metric_values(attempted, "actual_tool_calls"))

    %{
      "average_duration_s" => average(durations),
      "step_ratio" => ratio(actual_steps, expected_steps),
      "tool_call_ratio" => ratio(actual_tool_calls, expected_tool_calls),
      "solve_rate" => solve_rate(attempted)
    }
  end

  defp model_summaries(results) do
    results
    |> Enum.group_by(& &1["model"])
    |> Map.new(fn {model, rows} -> {model, summarize_results_without_models(rows)} end)
  end

  defp summarize_results_without_models(results) do
    total = length(results)
    skipped = Enum.count(results, & &1["skipped"])
    passed = Enum.count(results, &(&1["passed"] == true))
    failed = total - skipped - passed
    attempted = total - skipped

    %{
      "total" => total,
      "passed" => passed,
      "failed" => failed,
      "skipped" => skipped,
      "pass_rate" => if(attempted == 0, do: 0.0, else: passed / attempted)
    }
  end

  defp metric_values(results, key) do
    results
    |> Enum.map(&get_in(&1, ["metrics", key]))
    |> Enum.filter(&is_number/1)
  end

  defp solve_rate(results) do
    values =
      results
      |> Enum.filter(& &1["passed"])
      |> Enum.flat_map(fn result ->
        expected = get_in(result, ["metrics", "expected_steps"])
        duration = get_in(result, ["metrics", "duration_s"])

        if is_number(expected) and is_number(duration) and duration > 0 do
          [expected / duration]
        else
          []
        end
      end)

    average(values)
  end

  defp average([]), do: nil
  defp average(values), do: Enum.sum(values) / length(values)
  defp ratio(_actual, 0), do: nil
  defp ratio(actual, expected), do: actual / expected
  defp duration_s(started_at), do: (System.monotonic_time(:millisecond) - started_at) / 1_000

  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(error), do: inspect(error)

  defp required_env("conversation"), do: ["BEAM_WEAVER_DEEPAGENTS_SANDBOX"]
  defp required_env(_category), do: []

  defp resolve_models(opts) do
    cond do
      model = Keyword.get(opts, :model) ->
        List.wrap(model) |> Enum.flat_map(&split_csv/1)

      group = Keyword.get(opts, :model_group) ->
        Map.get(@model_groups, group, [])

      true ->
        ["fake"]
    end
  end

  defp missing_provider_env(model, opts) do
    provider = provider_for_model(model)

    provider != "fake" and Keyword.get(opts, :include_live, false) and
      Map.has_key?(@provider_env, provider) and
      blank?(provider_api_key(provider))
  end

  defp missing_required_env(row) do
    row
    |> Map.get("required_env", [])
    |> Enum.any?(&missing_required_config?/1)
  end

  defp provider_api_key(provider) do
    with {:ok, provider_key} <- Map.fetch(@provider_config_key, provider) do
      Config.get([:evals, :provider_api_keys, provider_key]) ||
        Config.get([provider_key, :api_key])
    end
  end

  defp missing_required_config?("BEAM_WEAVER_DEEPAGENTS_SANDBOX"),
    do: not truthy?(Config.get([:evals, :external_sandbox?]))

  defp missing_required_config?(name), do: blank?(Config.get([:evals, :required, name]))

  defp truthy?(true), do: true

  defp truthy?(value) when is_binary(value),
    do: String.downcase(value) in ["1", "true", "yes", "on"]

  defp truthy?(_value), do: false

  defp provider_for_model(model) do
    model
    |> to_string()
    |> String.split(":", parts: 2)
    |> hd()
  end

  defp split_csv(value) when is_binary(value),
    do:
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

  defp split_csv(value), do: [to_string(value)]

  defp order_categories(categories) do
    Enum.sort_by(categories, fn category ->
      Enum.find_index(@categories, &(&1 == category)) || 999
    end)
  end

  defp trial_category_scores(trial) when is_map(trial),
    do: Map.get(trial, "category_scores") || get_in(trial, ["summary", "category_scores"]) || %{}

  defp trial_category_scores(_trial), do: %{}

  defp trial_index(%{"trial_index" => index}), do: index
  defp trial_index(%{trial_index: index}), do: index
  defp trial_index(_trial), do: nil

  defp markdown_cell(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("|", "\\|")
    |> String.replace("\n", " ")
    |> String.replace("\r", " ")
    |> String.trim()
  end

  defp format_float(value, places), do: :erlang.float_to_binary(value / 1, decimals: places)
  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false
end

defmodule BeamWeaver.TestSupport.DeepAgents.Evals.Radar do
  @moduledoc "Radar-data helpers for DeepAgents eval summaries."

  alias BeamWeaver.TestSupport.DeepAgents.Evals, as: Evals

  defmodule ModelResult do
    @moduledoc "Model-level scores used for radar output."
    defstruct model: nil, scores: %{}, metadata: %{}
  end

  @themes %{
    "light" => %{"background" => "#ffffff", "grid" => "#d0d7de", "text" => "#24292f"},
    "dark" => %{"background" => "#0d1117", "grid" => "#30363d", "text" => "#f0f6fc"}
  }

  def all_categories, do: Evals.radar_categories()
  def eval_categories, do: Evals.categories()
  def category_labels, do: Evals.category_labels()
  def themes, do: @themes

  def toy_data do
    [
      %ModelResult{
        model: "fake",
        scores: Map.new(Evals.radar_categories(), &{&1, 1.0}),
        metadata: %{"source" => "toy"}
      }
    ]
  end

  def load_results_from_summary(%{"category_scores" => scores}) do
    [%ModelResult{model: "aggregate", scores: scores}]
  end

  def load_results_from_summary(%{"models" => models}) when is_map(models) do
    Enum.map(models, fn {model, summary} ->
      %ModelResult{
        model: model,
        scores: Map.get(summary, "category_scores", %{}),
        metadata: Map.drop(summary, ["category_scores"])
      }
    end)
  end

  def load_results_from_summary(_summary), do: []

  def generate_radar(result, opts \\ [])

  def generate_radar(%ModelResult{} = result, opts) do
    result.scores
    |> then(&%{"category_scores" => &1})
    |> Evals.radar()
    |> Map.merge(%{
      "model" => result.model,
      "theme" => Map.get(@themes, to_string(Keyword.get(opts, :theme, "light")))
    })
  end

  def generate_radar(summary, opts) when is_map(summary) do
    summary
    |> load_results_from_summary()
    |> case do
      [result | _rest] -> generate_radar(result, opts)
      [] -> Evals.radar(%{"category_scores" => %{}})
    end
  end

  def generate_individual_radars(summary, opts \\ []) do
    summary
    |> load_results_from_summary()
    |> Map.new(&{&1.model, generate_radar(&1, opts)})
  end
end

defmodule BeamWeaver.TestSupport.DeepAgents.Evals.Failure do
  @moduledoc "Failure classification helpers for eval reports."

  @infrastructure ~w(timeout rate_limit missing_credentials sandbox_error provider_error)
  @task ~w(assertion_failed wrong_answer tool_error)

  def infrastructure_categories, do: @infrastructure
  def task_categories, do: @task

  def infrastructure?(category), do: to_string(category) in @infrastructure

  def classify_failure(value) do
    text = value |> inspect() |> String.downcase()

    cond do
      text =~ "timeout" -> "timeout"
      text =~ "rate limit" or text =~ "429" -> "rate_limit"
      text =~ "api key" or text =~ "credential" -> "missing_credentials"
      text =~ "sandbox" or text =~ "docker" -> "sandbox_error"
      text =~ "provider" or text =~ "http" -> "provider_error"
      text =~ "tool" -> "tool_error"
      true -> "assertion_failed"
    end
  end

  def extract_exit_codes(value) do
    ~r/(?:exit(?:ed)?(?: code)?|status)[^0-9-]*(-?\d+)/i
    |> Regex.scan(to_string(value), capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&String.to_integer/1)
  end
end

defmodule BeamWeaver.TestSupport.DeepAgents.Evals.Stats do
  @moduledoc "Small statistical helpers used by eval reporting."

  def wilson_ci(successes, total, z \\ 1.96)
  def wilson_ci(_successes, total, _z) when total <= 0, do: {0.0, 0.0}

  def wilson_ci(successes, total, z) do
    p = successes / total
    denom = 1 + z * z / total
    centre = p + z * z / (2 * total)
    margin = z * :math.sqrt((p * (1 - p) + z * z / (4 * total)) / total)
    {max(0.0, (centre - margin) / denom), min(1.0, (centre + margin) / denom)}
  end

  def format_ci({low, high}, places \\ 3),
    do: "#{format(low, places)}-#{format(high, places)}"

  def min_detectable_effect(baseline, samples, z \\ 1.96)

  def min_detectable_effect(baseline, samples, z)
      when samples > 0 and baseline >= 0 and baseline <= 1 do
    z * :math.sqrt(2 * baseline * (1 - baseline) / samples)
  end

  def min_detectable_effect(_baseline, _samples, _z), do: nil

  defp format(value, places), do: :erlang.float_to_binary(value / 1, decimals: places)
end

defmodule BeamWeaver.TestSupport.DeepAgents.Evals.Metadata do
  @moduledoc "Host and sandbox metadata collection for optional eval infrastructure."

  defmodule InfraMetadata do
    @moduledoc "Serializable eval infrastructure metadata."
    defstruct host: %{}, sandbox: %{}, collected_at: nil

    def to_map(%__MODULE__{} = metadata) do
      %{
        "host" => metadata.host,
        "sandbox" => metadata.sandbox,
        "collected_at" => metadata.collected_at
      }
    end
  end

  def collect_host_metadata do
    %{
      "otp_release" => System.otp_release(),
      "elixir_version" => System.version(),
      "system_architecture" => :erlang.system_info(:system_architecture) |> to_string(),
      "schedulers" => :erlang.system_info(:schedulers_online)
    }
  end

  def collect_sandbox_metadata(nil), do: %{"enabled" => false}

  def collect_sandbox_metadata(sandbox) do
    result = BeamWeaver.Sandbox.execute(sandbox, "uname -a", timeout: 5)

    cond do
      result.exit_code == 0 -> %{"enabled" => true, "uname" => String.trim(result.output || "")}
      result.error -> %{"enabled" => true, "error" => result.error}
      true -> %{"enabled" => true}
    end
  rescue
    exception -> %{"enabled" => true, "error" => Exception.message(exception)}
  end

  def collect(sandbox \\ nil) do
    %InfraMetadata{
      host: collect_host_metadata(),
      sandbox: collect_sandbox_metadata(sandbox),
      collected_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end
end

defmodule BeamWeaver.TestSupport.DeepAgents.Evals.Harbor do
  @moduledoc "Optional Harbor eval integration boundary."

  def enabled?, do: truthy?(BeamWeaver.Config.get([:evals, :deep_agents_harbor?]))

  def require_enabled! do
    unless enabled?() do
      raise "Harbor evals are disabled; configure :beam_weaver, :evals, deep_agents_harbor?: true"
    end
  end

  defp truthy?(true), do: true

  defp truthy?(value) when is_binary(value),
    do: String.downcase(value) in ["1", "true", "yes", "on"]

  defp truthy?(_value), do: false
end

defmodule BeamWeaver.TestSupport.DeepAgents.Evals.HarborSandbox do
  @moduledoc "Harbor-compatible sandbox adapter used by optional eval infrastructure."

  use BeamWeaver.Filesystem
  use BeamWeaver.Filesystem.Executable

  alias BeamWeaver.Filesystem
  alias BeamWeaver.Filesystem.Sandbox
  alias BeamWeaver.Filesystem.Executable

  @default_command_timeout_sec 120

  defstruct [:sandbox, timeout: @default_command_timeout_sec]

  def default_command_timeout_sec, do: @default_command_timeout_sec
  def new(opts \\ []), do: struct(__MODULE__, Map.new(opts))

  @impl Executable
  def id(%__MODULE__{sandbox: sandbox}), do: Map.get(sandbox || %{}, :id, "harbor-sandbox")

  @impl Executable
  def execute(%__MODULE__{sandbox: nil}, _command, _opts),
    do: %Executable.ExecuteResult{exit_code: nil, output: "", error: "missing_sandbox"}

  def execute(%__MODULE__{sandbox: sandbox, timeout: timeout}, command, opts),
    do:
      Sandbox.execute(
        Sandbox.new(sandbox: sandbox),
        command,
        Keyword.put_new(opts, :timeout, timeout)
      )

  @impl Filesystem
  def ls(%__MODULE__{sandbox: nil}, _path, _opts),
    do: %Filesystem.LsResult{error: "missing_sandbox"}

  def ls(%__MODULE__{sandbox: sandbox}, path, opts),
    do: Sandbox.ls(Sandbox.new(sandbox: sandbox), path, opts)

  @impl Filesystem
  def read(%__MODULE__{sandbox: nil}, _path, _opts),
    do: %Filesystem.ReadResult{error: "missing_sandbox"}

  def read(%__MODULE__{sandbox: sandbox}, path, opts),
    do: Sandbox.read(Sandbox.new(sandbox: sandbox), path, opts)

  @impl Filesystem
  def write(%__MODULE__{sandbox: nil}, path, _content, _opts),
    do: %Filesystem.WriteResult{path: path, error: "missing_sandbox"}

  def write(%__MODULE__{sandbox: sandbox}, path, content, opts),
    do: Sandbox.write(Sandbox.new(sandbox: sandbox), path, content, opts)

  @impl Filesystem
  def edit(%__MODULE__{sandbox: nil}, path, _old, _new, _opts),
    do: %Filesystem.EditResult{path: path, error: "missing_sandbox"}

  def edit(%__MODULE__{sandbox: sandbox}, path, old, new, opts),
    do: Sandbox.edit(Sandbox.new(sandbox: sandbox), path, old, new, opts)

  @impl Filesystem
  def glob(%__MODULE__{sandbox: nil}, _pattern, _opts),
    do: %Filesystem.GlobResult{error: "missing_sandbox"}

  def glob(%__MODULE__{sandbox: sandbox}, pattern, opts),
    do: Sandbox.glob(Sandbox.new(sandbox: sandbox), pattern, opts)

  @impl Filesystem
  def grep(%__MODULE__{sandbox: nil}, _pattern, _opts),
    do: %Filesystem.GrepResult{error: "missing_sandbox"}

  def grep(%__MODULE__{sandbox: sandbox}, pattern, opts),
    do: Sandbox.grep(Sandbox.new(sandbox: sandbox), pattern, opts)

  @impl Filesystem
  def upload_files(%__MODULE__{sandbox: nil}, files, _opts),
    do:
      Enum.map(files, fn {path, _content} ->
        %Filesystem.UploadResult{path: path, error: "missing_sandbox"}
      end)

  def upload_files(%__MODULE__{sandbox: sandbox}, files, opts),
    do: Sandbox.upload_files(Sandbox.new(sandbox: sandbox), files, opts)

  @impl Filesystem
  def download_files(%__MODULE__{sandbox: nil}, paths, _opts),
    do: Enum.map(paths, &%Filesystem.DownloadResult{path: &1, error: "missing_sandbox"})

  def download_files(%__MODULE__{sandbox: sandbox}, paths, opts),
    do: Sandbox.download_files(Sandbox.new(sandbox: sandbox), paths, opts)
end

defmodule BeamWeaver.TestSupport.DeepAgents.Evals.DeepAgentsWrapper do
  @moduledoc "Harbor-compatible wrapper around native BeamWeaver agents."

  @system_message "You are running inside the BeamWeaver DeepAgents eval harness."

  defstruct opts: [], agent: nil

  def system_message, do: @system_message
  def name(_wrapper \\ nil), do: "beam_weaver_deepagents"
  def version(_wrapper \\ nil), do: Keyword.get(Mix.Project.config(), :version, "dev")

  def new(opts \\ []), do: %__MODULE__{opts: opts}

  def setup(%__MODULE__{} = wrapper) do
    case BeamWeaver.Agent.build(wrapper.opts) do
      {:ok, agent} -> {:ok, %{wrapper | agent: agent}}
      {:error, error} -> {:error, error}
    end
  end

  def run(wrapper, input, opts \\ [])

  def run(%__MODULE__{agent: nil} = wrapper, input, opts) do
    with {:ok, wrapper} <- setup(wrapper), do: run(wrapper, input, opts)
  end

  def run(%__MODULE__{agent: agent}, input, opts) do
    messages =
      input
      |> List.wrap()
      |> Enum.map(fn
        %BeamWeaver.Core.Message{} = message -> message
        text -> BeamWeaver.Core.Message.user(to_string(text))
      end)

    BeamWeaver.Agent.invoke(agent, %{messages: messages}, opts)
  end
end

defmodule BeamWeaver.TestSupport.DeepAgents.Evals.ExternalSandbox do
  @moduledoc "Optional external sandbox eval integration gate."

  def enabled?, do: truthy?(BeamWeaver.Config.get([:evals, :external_sandbox?]))

  def require_enabled! do
    unless enabled?() do
      raise "External sandbox evals are disabled; configure :beam_weaver, :evals, external_sandbox?: true"
    end
  end

  defp truthy?(true), do: true

  defp truthy?(value) when is_binary(value),
    do: String.downcase(value) in ["1", "true", "yes", "on"]

  defp truthy?(_value), do: false
end
