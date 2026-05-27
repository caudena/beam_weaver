defmodule BeamWeaver.Transport.RedactorTest do
  use ExUnit.Case

  alias BeamWeaver.Transport.Redactor

  test "redacts headers, nested secret fields, bearer tokens, and OpenAI key shapes" do
    redacted =
      Redactor.redact(%{
        headers: [{"authorization", "Bearer live-token"}, {"content-type", "application/json"}],
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
end
