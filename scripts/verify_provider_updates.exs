# Real provider verification. No credentials or continuation-token values are logged.
# mix run scripts/verify_provider_updates.exs --case smoke --output _build/provider_live/run
# mix run scripts/verify_provider_updates.exs --case continuation --output _build/provider_live/run
# Other cases: argon, schema, deepseek-errors. Use a fresh output directory for each run.
# `continuation` deliberately requests enough output to cross Argon's 64K hop boundary.
Code.require_file("docs/credentials.exs", __DIR__)

defmodule BeamWeaver.LiveProviderVerification.Transport do
  @behaviour BeamWeaver.Transport
  alias BeamWeaver.Transport.ReqFinch
  alias BeamWeaver.Provider.SSE

  def request(request, opts) do
    {recorder, hop} = start(request, opts)
    started = System.monotonic_time(:millisecond)
    result = ReqFinch.request(request, Keyword.delete(opts, :recorder))

    case result do
      {:ok, response} ->
        record(recorder, %{
          event: "http_response",
          hop: hop,
          status: response.status,
          elapsed_ms: System.monotonic_time(:millisecond) - started
        })

      {:error, error} ->
        record(recorder, %{event: "http_error", hop: hop, type: error.type, message: error.message})
    end

    result
  end

  def stream_reduce(request, opts, acc, reducer) do
    {recorder, hop} = start(request, opts)
    started = System.monotonic_time(:millisecond)

    result =
      ReqFinch.stream_reduce(request, Keyword.delete(opts, :recorder), {acc, "", 0}, fn {acc, buffer, count}, chunk ->
        {events, buffer} = SSE.process_chunk(buffer, chunk)
        Enum.each(events, &observe(recorder, hop, &1))
        {reducer.(acc, chunk), buffer, count + 1}
      end)

    case result do
      {:ok, response, {acc, buffer, count}} ->
        {events, _} = SSE.process_chunk(buffer, "\n\n")
        Enum.each(events, &observe(recorder, hop, &1))

        record(recorder, %{
          event: "http_response",
          hop: hop,
          status: response.status,
          wire_chunks: count,
          elapsed_ms: System.monotonic_time(:millisecond) - started
        })

        {:ok, response, acc}

      {:error, error, {acc, _, count}} ->
        record(recorder, %{event: "http_error", hop: hop, type: error.type, message: error.message, wire_chunks: count})
        {:error, error, acc}
    end
  end

  defp start(request, opts) do
    recorder = Keyword.fetch!(opts, :recorder)
    # Compare JSON semantics: Elixir :low and "low" serialize identically.
    body = (request.json || Jason.decode!(request.body)) |> BeamWeaver.MapShape.stringify_keys()
    original = Map.delete(body, "continuationToken")

    hop =
      Agent.get_and_update(recorder, fn state ->
        n = state.hops + 1

        event = %{
          event: "http_request",
          hop: n,
          url: request.url,
          continuation: is_binary(body["continuationToken"]),
          original_request_unchanged: is_nil(state.original) or state.original == original,
          max_output_tokens: get_in(body, ["generationConfig", "maxOutputTokens"])
        }

        persist(state, event)
        {n, %{state | hops: n, original: state.original || original, events: [event | state.events]}}
      end)

    {recorder, hop}
  end

  defp observe(recorder, hop, %{"data" => %{} = response}) do
    candidate = get_in(response, ["candidates", Access.at(0)]) || %{}
    usage = response["usageMetadata"]
    token? = is_binary(candidate["continuationToken"])
    reason = candidate["finishReason"]

    text_bytes =
      candidate
      |> get_in(["content", "parts"])
      |> List.wrap()
      |> Enum.reduce(0, fn p, n -> n + byte_size(p["text"] || "") end)

    if reason || token? || usage || response["error"] do
      record(recorder, %{
        event: "provider_chunk",
        hop: hop,
        finish_reason: reason,
        continuation_token_present: token?,
        usage: usage,
        text_bytes: text_bytes,
        model_version: response["modelVersion"],
        provider_error: response["error"]
      })
    end
  end

  defp observe(_, _, _), do: :ok

  def record(recorder, event) do
    Agent.update(recorder, fn state ->
      persist(state, event)
      %{state | events: [event | state.events]}
    end)
  end

  defp persist(state, event),
    do:
      File.write!(state.path, Jason.encode!(Map.put(event, :at, DateTime.to_iso8601(DateTime.utc_now()))) <> "\n", [
        :append
      ])
end

defmodule BeamWeaver.LiveProviderVerification do
  alias BeamWeaver.Core.{ChatModel, Message}
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.LiveProviderVerification.Transport
  @continuation_budget 69_632

  def main(argv) do
    {opts, rest, invalid} = OptionParser.parse(argv, strict: [case: :string, output: :string])
    if invalid != [] or rest != [], do: raise("invalid arguments")
    output = Keyword.fetch!(opts, :output) |> Path.expand()
    File.mkdir_p!(output)
    BeamWeaver.Docs.Credentials.configure_live_providers!()

    case Keyword.fetch!(opts, :case) do
      "smoke" -> smoke(output)
      "argon" -> smoke(output, "argon")
      "schema" -> schema(output)
      "deepseek-errors" -> deepseek_errors(output)
      "continuation" -> continuation(output)
      other -> raise("unknown case: #{other}")
    end
  end

  defp smoke(output, prefix \\ "") do
    checks = [
      {"deepseek_search",
       fn recorder ->
         client =
           BeamWeaver.DeepSeek.Client.new(transport: Transport, transport_opts: [recorder: recorder], timeout: 60_000)

         with {:ok, result} <-
                BeamWeaver.DeepSeek.Client.search(client, %{
                  query: "Elixir programming language official website",
                  count: 5,
                  need_content: true
                }) do
           results = result["results"]
           true = is_list(results) and results != []
           true = Enum.all?(results, &(is_binary(&1["url"]) and is_binary(&1["title"])))

           %{
             result_count: length(results),
             results: Enum.map(results, &Map.take(&1, ["title", "url", "summary"])),
             nonempty_content_count: Enum.count(results, &((&1["content"] || "") != ""))
           }
         end
       end},
      {"deepseek_fetch",
       fn recorder ->
         client =
           BeamWeaver.DeepSeek.Client.new(transport: Transport, transport_opts: [recorder: recorder], timeout: 60_000)

         with {:ok, result} <- BeamWeaver.DeepSeek.Client.fetch(client, %{url: "https://elixir-lang.org/"}) do
           true = is_binary(result["content"]) and String.contains?(result["content"], "Elixir")
           File.write!(Path.join(output, "deepseek_fetch.txt"), result["content"])
           %{title: result["title"], content_bytes: byte_size(result["content"])}
         end
       end},
      {"argon_invoke",
       fn recorder ->
         model = google(recorder, max_output_tokens: 1_024, thinking_level: :low)

         with {:ok, reply} <- ChatModel.invoke(model, "Reply with exactly ARGON_OK and nothing else.") do
           true = String.trim(Message.text(reply)) == "ARGON_OK"
           true = reply.usage_metadata.initial_input_tokens == reply.usage_metadata.input_tokens
           summarize(reply)
         end
       end},
      {"argon_stream",
       fn recorder ->
         model = google(recorder, max_output_tokens: 2_048, thinking_level: :low)

         with {:ok, stream} <-
                ChatModel.stream_typed_events(
                  model,
                  "Write exactly 30 numbered lines, each explaining a different useful Elixir feature in one short sentence. Start with 1. and finish with 30."
                ) do
           result = collect(stream, output, "argon_stream")
           true = result.token_events > 0 and result.message_events == 1 and result.done_events == 1
           true = result.stream_matches_message
           true = result.usage.initial_input_tokens == result.usage.input_tokens
           true = String.contains?(File.read!(Path.join(output, "argon_stream.txt")), "30.")
           result
         end
       end}
    ]

    results =
      checks
      |> Enum.filter(fn {name, _} -> String.starts_with?(name, prefix) end)
      |> Enum.map(fn {name, fun} -> run(output, name, fun) end)

    if Enum.any?(results, &(&1.status != :pass)), do: System.halt(1)
  end

  defp continuation(output) do
    prompt = """
    You are creating a complete teaching dataset of 512 independent code-review exercises for an Elixir training course.
    Produce all 512 exercises, in ascending ID order, as newline-delimited JSON objects, one per line.
    Each object must contain: id (integer), topic (string), code (an executable Elixir example as a string), expected (the exact result),
    and explanation (a substantive explanation of 120-160 words walking through evaluation and one important edge case).
    The explanations are the teaching material, so do not replace them with terse summaries. Use varied examples, not duplicated templates.
    Distribute the topics across pattern matching, guards, lists, maps, binaries, recursion, Enum, Stream, processes, messages,
    monitors, links, GenServer, supervision, ETS, protocols, behaviours, structs, exceptions, and comprehensions.
    Do not introduce the dataset, use markdown fences, omit IDs, abbreviate sections, or offer to continue later.
    Do not run tools. This API supports automatic continuation beyond 65536 output tokens.
    The runtime will enforce this request's total output-token budget. A partial dataset at that limit is expected.
    Keep generating exercises in order until exercise 512 or the runtime stops generation; do not stop voluntarily
    to discuss response size or offer batching. Begin the exercises directly.
    """

    File.write!(Path.join(output, "argon_continuation_prompt.txt"), prompt)

    result =
      run(output, "argon_continuation", fn recorder ->
        model = google(recorder, max_output_tokens: @continuation_budget, thinking_level: :low)

        with {:ok, stream} <- ChatModel.stream_typed_events(model, prompt) do
          result = collect(stream, output, "argon_continuation")
          events = Agent.get(recorder, &Enum.reverse(&1.events))
          requests = Enum.filter(events, &(&1.event == "http_request"))
          continuations = Enum.filter(events, &(&1.event == "provider_chunk" and &1.finish_reason == "CONTINUATION"))
          true = result.token_events > 0 and result.message_events == 1 and result.done_events == 1
          true = result.stream_matches_message
          true = length(requests) >= 2 and continuations != []
          true = Enum.all?(requests, & &1.original_request_unchanged)
          true = Enum.any?(requests, & &1.continuation)

          terminal_usage =
            events
            |> Enum.filter(&(&1.event == "provider_chunk" and not is_nil(&1.usage)))
            |> Enum.group_by(& &1.hop)
            |> Enum.sort_by(&elem(&1, 0))
            |> Enum.map(fn {_, chunks} -> List.last(chunks).usage end)

          true = result.usage.input_tokens == Enum.sum(Enum.map(terminal_usage, &(&1["promptTokenCount"] || 0)))
          true = result.usage.initial_input_tokens == hd(terminal_usage)["promptTokenCount"]
          true = result.usage.total_tokens == Enum.sum(Enum.map(terminal_usage, &(&1["totalTokenCount"] || 0)))
          result |> Map.put(:continuation_hops, length(continuations)) |> Map.put(:request_count, length(requests))
        end
      end)

    if result.status != :pass, do: System.halt(1)
  end

  defp schema(output) do
    schema = %{type: "object", properties: %{answer: %{type: "integer"}}, required: ["answer"]}

    results =
      for {name, opts} <- [
            {"argon_portable_schema", [response_format: schema]},
            {"argon_native_schema",
             [response_format_config: %{"text" => %{"mimeType" => "APPLICATION_JSON", "schema" => schema}}]}
          ] do
        run(output, name, fn recorder ->
          model = google(recorder, max_output_tokens: 1_024, thinking_level: :low)

          with {:ok, reply} <- ChatModel.invoke(model, "Return a JSON object with answer equal to 42.", opts) do
            %{"answer" => 42} = Jason.decode!(Message.text(reply))
            summarize(reply)
          end
        end)
      end

    if Enum.any?(results, &(&1.status != :pass)), do: System.halt(1)
  end

  defp deepseek_errors(output) do
    results =
      for {name, fun, status} <- [
            {"deepseek_invalid_search",
             fn client -> BeamWeaver.DeepSeek.Client.search(client, %{query: "Elixir", count: 0}) end, 400},
            {"deepseek_missing_fetch",
             fn client ->
               BeamWeaver.DeepSeek.Client.fetch(client, %{
                 url: "https://elixir-lang.org/beamweaver-live-test-page-that-does-not-exist"
               })
             end, 404}
          ] do
        run(output, name, fn recorder ->
          client =
            BeamWeaver.DeepSeek.Client.new(transport: Transport, transport_opts: [recorder: recorder], timeout: 60_000)

          {:error, error} = fun.(client)
          true = error.details.status == status
          true = error.details.retryable == false

          %{
            provider_status: error.details.status,
            error_type: error.type,
            message: error.message,
            retryable: error.details.retryable
          }
        end)
      end

    if Enum.any?(results, &(&1.status != :pass)), do: System.halt(1)
  end

  defp google(recorder, opts),
    do:
      BeamWeaver.Models.init_chat_model!(
        "google:gemini-4-argon",
        [transport: Transport, transport_opts: [recorder: recorder], timeout: 1_200_000] ++ opts
      )

  defp collect(stream, output, name) do
    started = System.monotonic_time(:millisecond)

    collected =
      Enum.reduce(
        stream,
        %{tokens: [], token_events: 0, message_events: 0, done_events: 0, first_token_ms: nil, message: nil},
        fn envelope, acc ->
          case envelope.event do
            %Events.Token{text: text} ->
              %{
                acc
                | tokens: [text | acc.tokens],
                  token_events: acc.token_events + 1,
                  first_token_ms: acc.first_token_ms || System.monotonic_time(:millisecond) - started
              }

            %Events.Message{message: message} ->
              %{acc | message: message, message_events: acc.message_events + 1}

            %Events.Done{} ->
              %{acc | done_events: acc.done_events + 1}

            %Events.Error{error: error} ->
              raise("provider stream failed: #{inspect(BeamWeaver.Transport.Redactor.redact(error))}")

            _ ->
              acc
          end
        end
      )

    text = collected.tokens |> Enum.reverse() |> IO.iodata_to_binary()
    File.write!(Path.join(output, name <> ".txt"), text)

    result =
      Map.merge(
        summarize(collected.message),
        Map.take(collected, [:token_events, :message_events, :done_events, :first_token_ms])
      )
      |> Map.put(:stream_matches_message, text == Message.text(collected.message))

    File.write!(Path.join(output, name <> ".observed.json"), Jason.encode!(result, pretty: true))
    result
  end

  defp summarize(reply) do
    %{
      finish_reason: reply.status,
      text_bytes: byte_size(Message.text(reply)),
      usage: reply.usage_metadata,
      model: reply.response_metadata[:model_version],
      text_preview: String.slice(Message.text(reply), 0, 160)
    }
  end

  defp run(output, name, fun) do
    {:ok, recorder} =
      Agent.start_link(fn -> %{hops: 0, original: nil, events: [], path: Path.join(output, name <> ".jsonl")} end)

    started = System.monotonic_time(:millisecond)
    IO.puts("START #{name}")

    result =
      try do
        case fun.(recorder) do
          {:error, error} ->
            %{status: :fail, error: BeamWeaver.Transport.Redactor.redact(error) |> inspect(limit: :infinity)}

          details ->
            %{status: :pass, details: details}
        end
      rescue
        error -> %{status: :fail, error: Exception.format(:error, error, __STACKTRACE__)}
      end

    events = Agent.get(recorder, &Enum.reverse(&1.events))

    result =
      Map.merge(result, %{
        name: name,
        elapsed_ms: System.monotonic_time(:millisecond) - started,
        at: DateTime.to_iso8601(DateTime.utc_now()),
        requests: Enum.count(events, &(&1.event == "http_request"))
      })

    File.write!(Path.join(output, name <> ".result.json"), Jason.encode!(result, pretty: true))
    IO.puts(Jason.encode!(result))
    Agent.stop(recorder)
    result
  end
end

BeamWeaver.LiveProviderVerification.main(System.argv())
