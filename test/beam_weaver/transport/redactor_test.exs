defmodule BeamWeaver.Transport.RedactorTest do
  use ExUnit.Case

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

  test "keeps token count and generation limit fields while redacting credential tokens" do
    redacted =
      Redactor.redact(%{
        max_output_tokens: 512,
        max_completion_tokens: 128,
        max_tokens: 256,
        output_tokens: 42,
        thinking: %{budget_tokens: 1_024},
        access_token: "access-secret",
        credential_token: "credential-secret"
      })

    assert redacted.max_output_tokens == 512
    assert redacted.max_completion_tokens == 128
    assert redacted.max_tokens == 256
    assert redacted.output_tokens == 42
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
end
