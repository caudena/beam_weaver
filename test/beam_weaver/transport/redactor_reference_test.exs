defmodule BeamWeaver.Transport.RedactorReferenceTest do
  # The redactor skips work it can tell is not needed: patterns that can't
  # match, keys it has seen, parts with nothing to redact. These tests check
  # that it still redacts exactly what the plain reading of its rules does,
  # over random terms (`mix test --seed` replays a run).
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.ToolCall
  alias BeamWeaver.Transport.Redactor

  defmodule PlainRedactor do
    @moduledoc false

    # The redaction rules read plainly: every key normalized and checked,
    # every UTF-8 string decoded as JSON, then every pattern run.

    alias BeamWeaver.Core.Message

    @redacted "**REDACTED**"

    @secret_header_names ~w(authorization cookie set_cookie set-cookie x-api-key api-key openai-api-key proxy-authorization)
    @secret_key_parts ~w(api_key apikey private_key authorization token access_token refresh_token secret password credential)
    @usage_token_keys ~w(budget_tokens max_completion_tokens max_output_tokens max_tokens input_tokens output_tokens
                         total_tokens prompt_tokens completion_tokens cached_tokens reasoning_tokens input_token_details
                         input_tokens_details output_token_details output_tokens_details prompt_tokens_details
                         completion_tokens_details token_usage)

    def redact(headers) when is_list(headers) and headers != [] and is_tuple(hd(headers)) do
      Enum.map(headers, fn
        {key, value} ->
          if secret_key?(key), do: {to_string(key), @redacted}, else: {to_string(key), redact(value)}

        other ->
          redact(other)
      end)
    end

    def redact(values) when is_list(values), do: Enum.map(values, &redact/1)
    def redact(%{__struct__: module} = value) when module in [Date, DateTime, NaiveDateTime, Time], do: value

    def redact(%Message{} = message) do
      %Message{
        message
        | content: redact(message.content),
          metadata: redact(message.metadata),
          response_metadata: redact(message.response_metadata),
          usage_metadata: redact(message.usage_metadata),
          artifacts: redact(message.artifacts),
          server_tool_calls: redact(message.server_tool_calls),
          server_tool_results: redact(message.server_tool_results),
          tool_calls: redact(message.tool_calls)
      }
    end

    def redact(%{__struct__: _module} = value), do: value |> Map.from_struct() |> redact()

    def redact(value) when is_map(value) do
      Map.new(value, fn {key, map_value} ->
        if secret_key?(key), do: {key, @redacted}, else: {key, redact(map_value)}
      end)
    end

    def redact(value) when is_binary(value) do
      if String.valid?(value) do
        case BeamWeaver.JSON.decode(value) do
          {:ok, decoded} when is_map(decoded) or is_list(decoded) ->
            decoded |> redact() |> BeamWeaver.JSON.encode!(pretty: true)

          _not_json ->
            redact_string(value)
        end
      else
        value
      end
    end

    def redact(value), do: value

    defp secret_key?(key) do
      normalized = key |> to_string() |> String.downcase() |> String.replace("-", "_")

      not usage_or_limit_token_key?(normalized) and
        (normalized in @secret_header_names or Enum.any?(@secret_key_parts, &String.contains?(normalized, &1)))
    end

    defp usage_or_limit_token_key?(normalized) do
      normalized in @usage_token_keys or String.ends_with?(normalized, ["_tokens", "_token_count", "_token_limit"])
    end

    defp redact_string(value) do
      value
      |> String.replace(~r/-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----/s, @redacted)
      |> String.replace(~r/(https?:\/\/)[^\/@\s]+@/, "\\1#{@redacted}@")
      |> String.replace(
        ~r/([?&](?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|password|key)=)[^&\s'"]+/i,
        "\\1#{@redacted}"
      )
      |> String.replace(
        ~r/\b([A-Za-z0-9_]*(?:API_KEY|TOKEN|SECRET|PASSWORD|PRIVATE_KEY|CREDENTIAL)[A-Za-z0-9_]*\s*=\s*)([^\s'"&]+)/i,
        "\\1#{@redacted}"
      )
      |> String.replace(~r/Bearer\s+[A-Za-z0-9._~+\/=-]+/, "Bearer #{@redacted}")
      |> String.replace(~r/sk-[A-Za-z0-9_\-]+/, @redacted)
    end
  end

  @text_parts [
    "hello",
    " ",
    "=",
    " = ",
    "@",
    "Bearer ",
    "Bearer\t",
    "sk-",
    "sk-abc123",
    "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----",
    "-----BEGIN",
    "-----END PRIVATE KEY-----",
    "https://",
    "http://",
    "http://user:pw@host/x",
    "?",
    "&",
    "?api_key=",
    "?API-KEY=",
    "&apikey=",
    "&Access_Token=",
    "?refresh-token=",
    "?token=",
    "&TOKEN=",
    "?secret=",
    "&password=",
    "?key=",
    "?xkey=",
    "?_key=",
    "API_KEY=",
    "my_token\t=",
    "DB_PASSWORD = ",
    "password=hunter2",
    "a@b",
    "{",
    "}",
    "[",
    "]",
    "\"",
    "'",
    ":",
    ",",
    " \n\t\r",
    <<0xC2, 0xA0>>,
    <<0xC2, 0x85>>,
    <<0xFF>>,
    "é",
    "\u0130",
    "K",
    "{\"api_key\": \"v\"}",
    "[{\"token\": 1}]",
    "{\"a\": \"{\\\"token\\\": 2}\"}",
    "null",
    "1",
    "k",
    "B",
    "-",
    "The quick brown fox jumps over the lazy dog. ",
    "- bullet\n",
    "| --- | --- |\n"
  ]

  @keys [
    :role,
    :content,
    :api_key,
    :apiKey,
    :access_token,
    :max_tokens,
    :output_token_count,
    :x_token_limit,
    :password,
    :authorization,
    :cookie,
    :"set-cookie",
    :tokens,
    :Token,
    :"X-Api-Key",
    :secretary,
    :tokenizer,
    :model,
    :id,
    :name,
    :args,
    :status,
    :provider,
    :tooling,
    :usage,
    :ünï_token,
    nil,
    true,
    "api-key",
    "API_KEY",
    "Authorization",
    "Set-Cookie",
    "budget_tokens",
    "monkey",
    "PRIVATE-KEY",
    "private_key_id",
    "my_tokens",
    "a_token_count",
    "AP\u0130_KEY",
    "api_\u212Aey",
    "cookie",
    "COOKIE",
    "proxy-authorization",
    "",
    "role",
    <<0xFF, "token">>,
    1,
    2.5,
    {:tuple, :key},
    ~c"token"
  ]

  test "redacts what the plain reading of the rules redacts, for random terms" do
    for _term <- 1..1_500, do: assert_same_redaction(random_term(0))
  end

  test "redacts what the plain reading of the rules redacts, for random text and keys" do
    for _text <- 1..2_000 do
      text = random_text()
      assert_same_redaction(text)
      assert_same_redaction(%{Enum.random(@keys) => text, "list" => [{Enum.random(@keys), text}]})
    end
  end

  test "every common key gets the answer that checking its name gives" do
    for key <- [:id, :name, :type, :args, :call_id, :model, :provider, :usage, :tool_calls, :status, :description] do
      assert_same_redaction(%{key => "value", Atom.to_string(key) => "value"})
    end
  end

  defp assert_same_redaction(term) do
    expected = result(fn -> PlainRedactor.redact(term) end)
    assert result(fn -> Redactor.redact(term) end) === expected, "redacting #{inspect(term, limit: :infinity)}"
  end

  defp result(fun) do
    {:ok, fun.()}
  rescue
    exception -> {:raised, exception.__struct__}
  end

  defp random_text do
    case :rand.uniform(3) do
      1 -> join_random(@text_parts, 8)
      2 -> join_random(@text_parts, 120)
      3 -> String.duplicate("plain words go here, ", :rand.uniform(20)) <> join_random(@text_parts, 4)
    end
  end

  defp join_random(parts, max), do: Enum.map_join(1..:rand.uniform(max), fn _part -> Enum.random(parts) end)

  defp random_term(depth) when depth > 3, do: Enum.random([random_text(), :rand.uniform(1000), nil, :atom])

  defp random_term(depth) do
    case :rand.uniform(12) do
      1 -> random_text()
      2 -> Enum.random([:rand.uniform(1000), 1.5, nil, true, :atom, ~D[2024-01-01], ~U[2024-01-01 00:00:00Z]])
      3 -> Map.new(1..:rand.uniform(4), fn _key -> {Enum.random(@keys), random_term(depth + 1)} end)
      4 -> Map.new(1..:rand.uniform(40), fn index -> {"k#{index}", random_term(depth + 2)} end)
      5 -> Enum.map(1..:rand.uniform(3), fn _item -> random_term(depth + 1) end)
      6 -> Enum.map(1..:rand.uniform(3), fn _item -> {Enum.random(@keys), random_term(depth + 1)} end)
      7 -> assistant_message(depth)
      8 -> Message.user(random_text(), metadata: %{Enum.random(@keys) => random_text()})
      9 -> Message.tool(random_text(), tool_call_id: "call_1", metadata: %{status: "success"})
      10 -> %{json: random_json(), content: [%{"type" => "text", "text" => random_text()}]}
      11 -> Enum.random([MapSet.new([random_text()]), URI.parse("https://u:p@h/x?token=a"), 1..3, tool_call(depth)])
      12 -> Enum.random([[1 | 2], [{:a, 1} | :tail], {random_text(), :x}, [{:a, 1, 2}], %{__struct__: "x"}])
    end
  end

  defp assistant_message(depth) do
    call = tool_call(depth)

    Message.assistant(random_text(), metadata: %{Enum.random([:api_key, :note]) => random_text()}, tool_calls: [call])
    |> Map.put(:response_metadata, %{
      model: %{provider: :fake, model_name: "x"},
      tooling: %{calls: [call], call_count: 1},
      usage: %{input_tokens: 3, access_token: random_text()},
      headers: [{"authorization", random_text()}]
    })
  end

  defp tool_call(depth),
    do: %ToolCall{id: "call_1", name: "lookup", args: %{Enum.random(@keys) => random_term(depth + 2)}, type: :tool_call}

  defp random_json do
    case BeamWeaver.JSON.encode(%{Enum.random(["token", "name", "API_KEY"]) => random_text(), "list" => [1, "x"]}) do
      {:ok, json} -> Enum.random(["", " ", "\n\t", "x"]) <> json
      {:error, _not_utf8} -> "{\"unfinished\": 1"
    end
  end
end
