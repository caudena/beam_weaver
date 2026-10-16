defmodule BeamWeaver.Transport.RedactorTest do
  use ExUnit.Case

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Transport.Redactor

  test "redacts headers, nested secret fields, bearer tokens, and OpenAI key shapes" do
    redacted =
      Redactor.redact(%{
        headers: [{"authorization", "Bearer live-token"}, {"content-type", "application/json"}],
        response_headers: [{"set-cookie", "session=session-secret"}, {"cache-control", "private"}],
        body: %{
          "api_key" => "plain-live-secret",
          "messages" => [
            %{"role" => "user", "content" => "hello"}
          ],
          "nested" => %{"refresh_token" => "refresh-secret"}
        },
        text: "key sk-another-secret should not appear"
      })

    inspected = inspect(redacted)

    refute inspected =~ "live-token"
    refute inspected =~ "session-secret"
    refute inspected =~ "plain-live-secret"
    refute inspected =~ "refresh-secret"
    refute inspected =~ "sk-another-secret"
    assert inspected =~ "application/json"
    assert inspected =~ "hello"
    assert inspected =~ Redactor.redacted()
  end

  test "redacts secret fields inside JSON strings" do
    redacted = Redactor.redact(~s({"api_key":"plain-secret","prompt":"keep me"}))

    refute redacted =~ "plain-secret"
    assert redacted =~ "keep me"
    assert redacted =~ Redactor.redacted()
  end

  test "redacts JSON arrays and JSON strings that start with whitespace" do
    redacted = Redactor.redact(~s(  \n{"api_key": "plain-secret", "prompt": "keep me"}))

    refute redacted =~ "plain-secret"
    assert redacted =~ "keep me"
    refute Redactor.redact(~s([{"token": "array-secret"}])) =~ "array-secret"
  end

  test "redacts secret assignments whatever the name's case and the spaces around the equals sign" do
    for text <- ["export DB_PASSWORD = hunter2", "my_Token\t=hunter2", "ApiKey: x, API_KEY  =hunter2"] do
      redacted = Redactor.redact(text)

      refute redacted =~ "hunter2"
      assert redacted =~ Redactor.redacted()
    end
  end

  test "keeps text without secrets, and binaries that aren't UTF-8, as they are" do
    text = String.duplicate("Order A-1001 shipped on Monday; count = 3, mail a@b. ", 40)
    not_utf8 = <<0xFF, "API_KEY=hunter2 sk-abc">>

    assert Redactor.redact(text) == text
    assert Redactor.redact(not_utf8) == not_utf8
  end

  test "keeps token count and generation limit fields while redacting credential tokens" do
    redacted =
      Redactor.redact(%{
        max_output_tokens: 512,
        max_completion_tokens: 128,
        max_tokens: 256,
        output_tokens: 42,
        input_tokens_details: %{image_tokens: 7, text_tokens: 3},
        output_tokens_details: %{image_tokens: 12},
        thinking: %{budget_tokens: 1_024},
        access_token: "access-secret",
        credential_token: "credential-secret"
      })

    assert redacted.max_output_tokens == 512
    assert redacted.max_completion_tokens == 128
    assert redacted.max_tokens == 256
    assert redacted.output_tokens == 42
    assert redacted.input_tokens_details == %{image_tokens: 7, text_tokens: 3}
    assert redacted.output_tokens_details == %{image_tokens: 12}
    assert redacted.thinking.budget_tokens == 1_024
    assert redacted.access_token == Redactor.redacted()
    assert redacted.credential_token == Redactor.redacted()
  end

  test "redacts URL credentials, query secrets, env-style assignments, and private keys" do
    redacted =
      Redactor.redact(%{
        command:
          "OPENAI_API_KEY=env-secret curl -H 'Authorization: Bearer live-token' " <>
            "https://user:password-secret@example.com/path?access_token=url-token&prompt=keep",
        private_key: """
        -----BEGIN PRIVATE KEY-----
        private-key-secret
        -----END PRIVATE KEY-----
        """,
        callback_url: "https://example.com/hook?api_key=query-secret&name=keep-me"
      })

    inspected = inspect(redacted)

    refute inspected =~ "env-secret"
    refute inspected =~ "live-token"
    refute inspected =~ "password-secret"
    refute inspected =~ "url-token"
    refute inspected =~ "private-key-secret"
    refute inspected =~ "query-secret"
    assert inspected =~ "example.com"
    assert inspected =~ "prompt=keep"
    assert inspected =~ "name=keep-me"
    assert inspected =~ Redactor.redacted()
  end

  test "gives back the parts of a term with nothing to redact as they are" do
    messages = [
      Message.system("You are Acme's support agent."),
      Message.user("Where is my order A-1001?", metadata: %{source: "chat"}),
      Message.assistant("It shipped on Monday.", response_metadata: %{model: %{provider: :fake, name: "chat"}})
    ]

    assert same?(Redactor.redact(messages), messages)

    request = %{settings: %{model: "chat", retries: [1, 2, 3], labels: %{"team" => "support"}}, api_key: "secret"}
    redacted = Redactor.redact(request)

    assert redacted.api_key == Redactor.redacted()
    assert same?(redacted.settings, request.settings)
  end

  test "runs no regular expression over long text whose = and @ are not part of a secret" do
    text =
      String.duplicate(
        "for (let i = 2; i * i <= n; i++) { total += i } // ask support@example.com, see https://example.com/a?b=c\n",
        40
      )

    assert regex_calls(fn -> assert Redactor.redact(text) == text end) == 0

    secret = text <> "OPENAI_API_KEY=env-secret"
    assert regex_calls(fn -> refute Redactor.redact(secret) =~ "env-secret" end) > 0
  end

  defp same?(left, right), do: :erts_debug.same(left, right)

  # Counts the calls into `:re`, which runs regular expressions, that `fun`
  # makes. A process can't trace itself, so another one counts.
  defp regex_calls(fun) do
    test = self()
    counter = spawn_link(fn -> count_regex_calls(test, 0) end)
    :erlang.trace_pattern({:re, :_, :_}, true, [:local])
    :erlang.trace(test, true, [:call, {:tracer, counter}])

    try do
      fun.()
    after
      :erlang.trace(test, false, [:call])
      :erlang.trace_pattern({:re, :_, :_}, false, [:local])
    end

    ref = :erlang.trace_delivered(test)
    assert_receive {:trace_delivered, ^test, ^ref}
    send(counter, :count)
    assert_receive {:regex_calls, count}
    count
  end

  defp count_regex_calls(test, count) do
    receive do
      {:trace, ^test, :call, {:re, _function, _args}} -> count_regex_calls(test, count + 1)
      :count -> send(test, {:regex_calls, count})
    end
  end
end
