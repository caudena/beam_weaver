Application.ensure_all_started(:ex_unit)
Application.ensure_all_started(:beam_weaver)

Code.require_file(Path.expand("../support/provider_conformance.exs", __DIR__))

defmodule BeamWeaver.DeepSeekLiveCapture do
  @moduledoc false

  alias BeamWeaver.DeepSeek.Client
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.TestSupport.ProviderConformance.CaptureTransport

  @capture_guard "BEAM_WEAVER_CAPTURE_DEEPSEEK"
  @api_key_env "DEEPSEEK_API_KEY"
  @capture_dir_env "DEEPSEEK_CAPTURE_DIR"
  @timeout 120_000
  @flash "deepseek-v4-flash"
  @pro "deepseek-v4-pro"

  def run do
    with :ok <- require_capture_guard(),
         {:ok, api_key} <- required_api_key() do
      context = %{api_key: api_key, output_dir: output_dir!()}
      File.mkdir_p!(context.output_dir)

      entries = []
      entries = capture_account_surface(context, entries)
      entries = Enum.reduce([@flash, @pro], entries, &capture_chat_model(context, &2, &1))
      entries = Enum.reduce([@flash, @pro], entries, &capture_fim_model(context, &2, &1))
      entries = capture_responses(context, entries)
      entries = capture_anthropic(context, entries)
      entries = Enum.reverse(entries)
      manifest_path = write_manifest!(context, entries)

      case Enum.reject(entries, &successful_entry?/1) do
        [] ->
          Mix.shell().info("DeepSeek live capture complete: #{length(entries)} scenarios -> #{manifest_path}")

        failures ->
          Mix.shell().error(
            "DeepSeek live capture recorded #{length(failures)} unexpected failure(s) -> #{manifest_path}"
          )

          System.halt(1)
      end
    else
      {:error, :capture_disabled} ->
        Mix.shell().info("DeepSeek live capture is disabled; set #{@capture_guard}=true to enable it.")

      {:error, :missing_api_key} ->
        Mix.shell().error("DeepSeek live capture requires #{@api_key_env}.")
        System.halt(1)
    end
  end

  defp capture_account_surface(context, entries) do
    {_result, entries} = capture(context, entries, "models", &Client.models/1)
    {_result, entries} = capture(context, entries, "balance", &Client.balance/1)

    {_result, entries} =
      capture(
        context,
        entries,
        "invalid_request",
        &Client.chat_completions(&1, %{"messages" => []}),
        expected_error: true
      )

    {_result, entries} =
      capture(
        context,
        entries,
        "invalid_auth",
        &Client.chat_completions(&1, basic_chat_body(@flash)),
        api_key: "deepseek-invalid-capture-key",
        expected_error: true
      )

    entries
  end

  defp capture_chat_model(context, entries, model) do
    slug = model_slug(model)

    {_result, entries} =
      capture(
        context,
        entries,
        "chat_#{slug}_basic",
        &Client.chat_completions(&1, basic_chat_body(model))
      )

    {_result, entries} =
      capture(
        context,
        entries,
        "chat_#{slug}_thinking",
        &Client.chat_completions(&1, thinking_chat_body(model))
      )

    {_result, entries} =
      capture(
        context,
        entries,
        "chat_#{slug}_stream",
        &Client.chat_completions_stream(&1, streaming_chat_body(model)),
        mode: :stream
      )

    {_result, entries} =
      capture(
        context,
        entries,
        "chat_#{slug}_json",
        &Client.chat_completions(&1, json_chat_body(model))
      )

    cache_body = cache_chat_body(model)

    {_result, entries} =
      capture(
        context,
        entries,
        "chat_#{slug}_cache_first",
        &Client.chat_completions(&1, cache_body)
      )

    {_result, entries} =
      capture(
        context,
        entries,
        "chat_#{slug}_cache_second",
        &Client.chat_completions(&1, cache_body)
      )

    {_result, entries} =
      capture(
        context,
        entries,
        "chat_#{slug}_prefix",
        &Client.chat_completions(&1, prefix_chat_body(model))
      )

    {_result, entries} =
      capture(
        context,
        entries,
        "chat_#{slug}_strict_tool",
        &Client.chat_completions(&1, strict_tool_chat_body(model))
      )

    capture_chat_tool_replay(context, entries, model, slug)
  end

  defp capture_chat_tool_replay(context, entries, model, slug) do
    prerequisite_body = thinking_tool_chat_body(model)

    {result, entries} =
      capture(
        context,
        entries,
        "chat_#{slug}_tool_call",
        &Client.chat_completions(&1, prerequisite_body)
      )

    case chat_tool_replay_body(result, prerequisite_body) do
      {:ok, replay_body} ->
        {_result, entries} =
          capture(
            context,
            entries,
            "chat_#{slug}_tool_replay",
            &Client.chat_completions(&1, replay_body)
          )

        entries

      {:error, reason} ->
        record_scenario_failure(context, entries, "chat_#{slug}_tool_replay", reason)
    end
  end

  defp capture_fim_model(context, entries, model) do
    slug = model_slug(model)

    {_result, entries} =
      capture(
        context,
        entries,
        "fim_#{slug}_sync",
        &Client.completions(&1, fim_body(model))
      )

    {_result, entries} =
      capture(
        context,
        entries,
        "fim_#{slug}_stream",
        &Client.completions_stream(&1, Map.put(fim_body(model), "stream", true)),
        mode: :stream
      )

    entries
  end

  defp capture_responses(context, entries) do
    scenarios = [
      {"responses_flash_sync", responses_basic_body(), []},
      {"responses_flash_stream", Map.put(responses_basic_body(), "stream", true), mode: :stream},
      {"responses_flash_schema", responses_schema_body(), []},
      {"responses_flash_function", responses_function_body(), []},
      {"responses_flash_forced_function_no_thinking", responses_forced_function_body(), []},
      {"responses_flash_web_search", responses_web_search_body(), []},
      {"responses_flash_apply_patch", responses_apply_patch_body(), []},
      {"responses_pro_sync", responses_basic_body(@pro), []},
      {"responses_pro_stream", Map.put(responses_basic_body(@pro), "stream", true), mode: :stream}
    ]

    Enum.reduce(scenarios, entries, fn {scenario, body, opts}, acc ->
      request =
        if Keyword.get(opts, :mode) == :stream,
          do: &Client.responses_stream(&1, body),
          else: &Client.responses(&1, body)

      {_result, acc} =
        capture(
          context,
          acc,
          scenario,
          request,
          Keyword.put(opts, :provider, :deepseek_responses)
        )

      acc
    end)
  end

  defp capture_anthropic(context, entries) do
    aliases = [
      {"sonnet_flash", "claude-sonnet-4-5"},
      {"opus_pro", "claude-opus-4-1"}
    ]

    Enum.reduce(aliases, entries, fn {slug, model}, acc ->
      {_result, acc} =
        capture(
          context,
          acc,
          "anthropic_#{slug}_sync",
          &Client.anthropic_messages(&1, anthropic_basic_body(model))
        )

      {_result, acc} =
        capture(
          context,
          acc,
          "anthropic_#{slug}_stream",
          &Client.anthropic_messages_stream(
            &1,
            Map.put(anthropic_basic_body(model), "stream", true)
          ),
          mode: :stream
        )

      {_result, acc} =
        capture(
          context,
          acc,
          "anthropic_#{slug}_thinking",
          &Client.anthropic_messages(&1, anthropic_thinking_body(model))
        )

      {_result, acc} =
        capture(
          context,
          acc,
          "anthropic_#{slug}_tools",
          &Client.anthropic_messages(&1, anthropic_tool_body(model))
        )

      acc
    end)
  end

  defp capture(context, entries, scenario, request, opts \\ []) do
    path = capture_path(context, scenario)
    client = capture_client(context, scenario, path, opts)

    try do
      result = request.(client)
      result = maybe_consume_stream(result, Keyword.get(opts, :mode, :sync))
      status = result_status(result, Keyword.get(opts, :expected_error, false))
      entry = capture_entry(scenario, status, path)
      print_summary(entry)
      {result, [entry | entries]}
    rescue
      exception ->
        failure = "exception_#{exception.__struct__ |> Module.split() |> List.last()}"
        failure_path = ensure_failure_record(context, scenario, path, failure)
        entry = capture_entry(scenario, "failed_#{failure}", failure_path)
        print_summary(entry)
        {{:capture_exception, exception.__struct__}, [entry | entries]}
    catch
      kind, _reason ->
        failure = "caught_#{kind}"
        failure_path = ensure_failure_record(context, scenario, path, failure)
        entry = capture_entry(scenario, "failed_#{failure}", failure_path)
        print_summary(entry)
        {{:capture_caught, kind}, [entry | entries]}
    end
  end

  defp maybe_consume_stream(result, :sync), do: result

  defp maybe_consume_stream({:ok, enumerable}, :stream) do
    items = Enum.to_list(enumerable)

    case Enum.find_value(items, fn
           %Events.Error{error: error} -> error
           _item -> nil
         end) do
      nil -> {:ok, %{stream_items: length(items)}}
      error -> {:error, error}
    end
  end

  defp maybe_consume_stream({:error, _error} = error, :stream), do: error
  defp maybe_consume_stream(other, :stream), do: {:error, {:invalid_stream_result, result_kind(other)}}

  defp capture_client(context, scenario, path, opts) do
    Client.new(
      api_key: Keyword.get(opts, :api_key, context.api_key),
      timeout: @timeout,
      transport: CaptureTransport,
      transport_opts: [
        capture_provider: Keyword.get(opts, :provider, :deepseek),
        capture_scenario: scenario,
        capture_path: path
      ]
    )
  end

  defp result_status({:ok, _result}, false), do: "ok"
  defp result_status({:ok, _result}, true), do: "unexpected_success"

  defp result_status({:error, error}, expected_error?) do
    prefix = if expected_error?, do: "expected_error", else: "failed"
    "#{prefix}_#{safe_error_type(error)}"
  end

  defp result_status(other, _expected_error?), do: "failed_#{result_kind(other)}"

  defp safe_error_type(%{type: type}) when is_atom(type), do: Atom.to_string(type)
  defp safe_error_type(%{__struct__: module}), do: module |> Module.split() |> List.last() |> Macro.underscore()
  defp safe_error_type(_error), do: "unknown_error"

  defp result_kind({tag, _value}) when is_atom(tag), do: Atom.to_string(tag)
  defp result_kind(value) when is_atom(value), do: Atom.to_string(value)
  defp result_kind(_value), do: "unexpected_result"

  defp chat_tool_replay_body({:ok, response}, prerequisite_body) when is_map(response) do
    with [%{"message" => message} | _rest] when is_map(message) <- response["choices"],
         [_call | _rest] = tool_calls <- message["tool_calls"],
         true <- Enum.all?(tool_calls, &valid_chat_tool_call?/1) do
      assistant =
        message
        |> Map.take(["role", "content", "reasoning_content", "tool_calls"])
        |> Map.put_new("role", "assistant")
        |> Map.put("tool_calls", tool_calls)

      tool_results =
        Enum.map(tool_calls, fn call ->
          %{
            "role" => "tool",
            "tool_call_id" => call["id"],
            "name" => get_in(call, ["function", "name"]),
            "content" => BeamWeaver.JSON.encode!(%{"temperature_c" => 22})
          }
        end)

      {:ok,
       prerequisite_body
       |> Map.put("messages", prerequisite_body["messages"] ++ [assistant] ++ tool_results)
       |> Map.put("tool_choice", "auto")}
    else
      _missing_tool_call -> {:error, "prerequisite_did_not_return_a_valid_tool_call"}
    end
  end

  defp chat_tool_replay_body(_result, _prerequisite_body),
    do: {:error, "prerequisite_request_failed"}

  defp valid_chat_tool_call?(%{
         "id" => id,
         "function" => %{"name" => name, "arguments" => arguments}
       }) do
    is_binary(id) and id != "" and is_binary(name) and name != "" and is_binary(arguments)
  end

  defp valid_chat_tool_call?(_call), do: false

  defp record_scenario_failure(context, entries, scenario, reason) do
    path = failure_path(context, scenario)

    write_json!(path, %{
      "provider" => "deepseek",
      "scenario" => scenario,
      "status" => "failed",
      "reason" => reason
    })

    entry = capture_entry(scenario, "failed_#{reason}", path)
    print_summary(entry)
    [entry | entries]
  end

  defp ensure_failure_record(context, scenario, capture_path, reason) do
    if File.exists?(capture_path) do
      capture_path
    else
      path = failure_path(context, scenario)

      write_json!(path, %{
        "provider" => "deepseek",
        "scenario" => scenario,
        "status" => "failed",
        "reason" => reason
      })

      path
    end
  end

  defp capture_entry(scenario, status, path) do
    %{"scenario" => scenario, "status" => status, "path" => path}
  end

  defp successful_entry?(%{"status" => "ok"}), do: true
  defp successful_entry?(%{"status" => "expected_error_" <> _type}), do: true
  defp successful_entry?(_entry), do: false

  defp print_summary(entry) do
    Mix.shell().info("#{entry["scenario"]}: #{entry["status"]} -> #{entry["path"]}")
  end

  defp basic_chat_body(model) do
    %{
      "model" => model,
      "messages" => [%{"role" => "user", "content" => "Reply with exactly: pong"}],
      "thinking" => %{"type" => "disabled"},
      "max_tokens" => 32
    }
  end

  defp thinking_chat_body(model) do
    %{
      "model" => model,
      "messages" => [%{"role" => "user", "content" => "Think briefly, then answer: 17 * 19"}],
      "thinking" => %{"type" => "enabled"},
      "reasoning_effort" => "low",
      "max_tokens" => 96
    }
  end

  defp streaming_chat_body(model) do
    model
    |> thinking_chat_body()
    |> Map.merge(stream_fields())
  end

  defp json_chat_body(model) do
    %{
      "model" => model,
      "messages" => [
        %{
          "role" => "user",
          "content" => ~s(Return JSON only, exactly matching this shape: {"answer":"pong"}. The answer must be pong.)
        }
      ],
      "thinking" => %{"type" => "disabled"},
      "response_format" => %{"type" => "json_object"},
      "max_tokens" => 64
    }
  end

  defp cache_chat_body(model) do
    stable_prefix = String.duplicate("This is a stable DeepSeek cache validation prefix. ", 128)

    %{
      "model" => model,
      "messages" => [
        %{"role" => "system", "content" => stable_prefix},
        %{"role" => "user", "content" => "Reply with exactly: cached pong"}
      ],
      "thinking" => %{"type" => "disabled"},
      "max_tokens" => 32
    }
  end

  defp prefix_chat_body(model) do
    %{
      "model" => model,
      "messages" => [
        %{"role" => "user", "content" => "Complete the sentence with one word."},
        %{"role" => "assistant", "content" => "The sky is", "prefix" => true}
      ],
      "thinking" => %{"type" => "disabled"},
      "max_tokens" => 16
    }
  end

  defp strict_tool_chat_body(model) do
    %{
      "model" => model,
      "messages" => [
        %{"role" => "user", "content" => "Call get_weather for Nicosia. Do not answer directly."}
      ],
      "thinking" => %{"type" => "disabled"},
      "tools" => [chat_weather_tool(true)],
      "tool_choice" => %{"type" => "function", "function" => %{"name" => "get_weather"}},
      "max_tokens" => 64
    }
  end

  defp thinking_tool_chat_body(model) do
    %{
      "model" => model,
      "messages" => [
        %{"role" => "user", "content" => "Call get_weather for Nicosia. Do not answer directly."}
      ],
      "thinking" => %{"type" => "enabled"},
      "reasoning_effort" => "low",
      "tools" => [chat_weather_tool(false)],
      "max_tokens" => 128
    }
  end

  defp chat_weather_tool(strict?) do
    function = %{
      "name" => "get_weather",
      "description" => "Return the current weather for a city.",
      "parameters" => weather_schema()
    }

    function = if strict?, do: Map.put(function, "strict", true), else: function
    %{"type" => "function", "function" => function}
  end

  defp fim_body(model) do
    %{
      "model" => model,
      "prompt" => "def fibonacci(n):\n    ",
      "suffix" => "\n\nprint(fibonacci(10))",
      "max_tokens" => 48,
      "logprobs" => 2
    }
  end

  defp responses_basic_body(model \\ @flash) do
    %{
      "model" => model,
      "input" => "Reply with exactly: responses pong",
      "max_output_tokens" => 48
    }
  end

  defp responses_schema_body do
    %{
      "model" => @flash,
      "input" => "Return an answer field whose value is exactly pong.",
      "text" => %{
        "format" => %{
          "type" => "json_schema",
          "name" => "capture_answer",
          "strict" => true,
          "schema" => answer_schema()
        }
      },
      "max_output_tokens" => 64
    }
  end

  defp responses_function_body do
    %{
      "model" => @flash,
      "input" => "Call get_weather for Nicosia. Do not answer directly.",
      "tools" => [responses_weather_tool()],
      "tool_choice" => "auto",
      "max_output_tokens" => 96
    }
  end

  defp responses_forced_function_body do
    responses_function_body()
    |> Map.put("reasoning", %{"effort" => "none"})
    |> Map.put("tool_choice", %{"type" => "function", "name" => "get_weather"})
  end

  defp responses_web_search_body do
    %{
      "model" => @flash,
      "input" => "Search the web for the current DeepSeek API model names and summarize briefly.",
      "tools" => [%{"type" => "web_search"}],
      "tool_choice" => %{"type" => "web_search"},
      "max_output_tokens" => 2_048
    }
  end

  defp responses_apply_patch_body do
    %{
      "model" => @flash,
      "input" => "Use apply_patch to add a single line containing hello to capture.txt.",
      "tools" => [
        %{
          "type" => "custom",
          "name" => "apply_patch",
          "format" => %{
            "type" => "grammar",
            "syntax" => "lark",
            "definition" => "start: /[\\s\\S]+/"
          }
        }
      ],
      "tool_choice" => "auto",
      "max_output_tokens" => 128
    }
  end

  defp responses_weather_tool do
    %{
      "type" => "function",
      "name" => "get_weather",
      "description" => "Return the current weather for a city.",
      "parameters" => weather_schema(),
      "strict" => true
    }
  end

  defp anthropic_basic_body(model) do
    %{
      "model" => model,
      "max_tokens" => 48,
      "messages" => [
        %{
          "role" => "user",
          "content" => [%{"type" => "text", "text" => "Reply with exactly: anthropic pong"}]
        }
      ]
    }
  end

  defp anthropic_thinking_body(model) do
    %{
      "model" => model,
      "max_tokens" => 1_024,
      "thinking" => %{"type" => "enabled", "budget_tokens" => 512},
      "output_config" => %{"effort" => "low"},
      "messages" => [
        %{"role" => "user", "content" => "Think briefly, then answer: 23 * 29"}
      ]
    }
  end

  defp anthropic_tool_body(model) do
    %{
      "model" => model,
      "max_tokens" => 128,
      "messages" => [
        %{"role" => "user", "content" => "Call get_weather for Nicosia. Do not answer directly."}
      ],
      "thinking" => %{"type" => "disabled"},
      "tools" => [
        %{
          "name" => "get_weather",
          "description" => "Return the current weather for a city.",
          "input_schema" => weather_schema()
        }
      ],
      "tool_choice" => %{"type" => "tool", "name" => "get_weather"}
    }
  end

  defp weather_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{"city" => %{"type" => "string"}},
      "required" => ["city"]
    }
  end

  defp answer_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{"answer" => %{"type" => "string"}},
      "required" => ["answer"]
    }
  end

  defp stream_fields do
    %{"stream" => true, "stream_options" => %{"include_usage" => true}}
  end

  defp model_slug(@flash), do: "flash"
  defp model_slug(@pro), do: "pro"

  defp require_capture_guard do
    if System.get_env(@capture_guard) == "true",
      do: :ok,
      else: {:error, :capture_disabled}
  end

  defp required_api_key do
    case System.get_env(@api_key_env) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, :missing_api_key}
    end
  end

  defp output_dir! do
    case System.get_env(@capture_dir_env) do
      value when is_binary(value) and value != "" ->
        Path.expand(value)

      _missing ->
        fresh_temp_output_dir!()
    end
  end

  defp fresh_temp_output_dir! do
    suffix =
      12
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    path = Path.join(System.tmp_dir!(), "beam_weaver-deepseek-live-#{suffix}")

    case File.mkdir(path) do
      :ok -> path
      {:error, :eexist} -> fresh_temp_output_dir!()
      {:error, reason} -> raise File.Error, reason: reason, action: "create directory", path: path
    end
  end

  defp capture_path(context, scenario), do: Path.join(context.output_dir, "#{scenario}.json")
  defp failure_path(context, scenario), do: Path.join(context.output_dir, "#{scenario}.failure.json")

  defp write_manifest!(context, entries) do
    path = Path.join(context.output_dir, "manifest.json")

    write_json!(path, %{
      "captured_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "timeout_ms" => @timeout,
      "scenario_count" => length(entries),
      "scenarios" => entries
    })

    path
  end

  defp write_json!(path, value) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, BeamWeaver.JSON.encode!(value, pretty: true) <> "\n")
  end
end

BeamWeaver.DeepSeekLiveCapture.run()
