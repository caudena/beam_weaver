defmodule BeamWeaver.Agent.PIIMiddlewareTest do
  use ExUnit.Case, async: true

  # Upstream reference:

  alias BeamWeaver.Agent.Middleware.PII
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph.Overwrite

  test "detector helpers return typed matches with offsets" do
    assert [%{type: "email", value: "john.doe@example.com", start: 14, end: 34}] =
             PII.detect_email("Contact me at john.doe@example.com for more info.")

    assert [%{value: "alice@test.com"}, %{value: "bob@company.org"}] =
             PII.detect_email("Email alice@test.com or bob@company.org")

    assert [] = PII.detect_email("Invalid emails: @test.com, user@, user@domain")
    assert [] = PII.detect_email("This text has no email addresses.")

    assert [%{type: "credit_card", value: "4532-0151-1283-0366"}] =
             PII.detect_credit_card("Card: 4532-0151-1283-0366")

    assert [%{value: "5425 2334 3010 9903"}] =
             PII.detect_credit_card("Card: 5425 2334 3010 9903")

    assert [] = PII.detect_credit_card("Card: 1234567890123456")
    assert [] = PII.detect_credit_card("No cards here.")

    assert [%{type: "ip", value: "192.168.1.1"}] = PII.detect_ip("Server IP: 192.168.1.1")
    assert [%{value: "10.0.0.1"}, %{value: "8.8.8.8"}] = PII.detect_ip("IPs 10.0.0.1 8.8.8.8")
    assert [] = PII.detect_ip("Not an IP: 999.999.999.999")

    assert [%{type: "mac_address", value: "00:1A:2B:3C:4D:5E"}] =
             PII.detect_mac_address("MAC: 00:1A:2B:3C:4D:5E")

    assert [%{value: "00-1A-2B-3C-4D-5E"}] =
             PII.detect_mac_address("MAC: 00-1A-2B-3C-4D-5E")

    assert [%{value: "aa:bb:cc:dd:ee:ff"}] =
             PII.detect_mac_address("MAC: aa:bb:cc:dd:ee:ff")

    assert [] = PII.detect_mac_address("Partial: 00:1A:2B:3C")
    assert [] = PII.detect_mac_address("No MAC address here.")

    assert [%{value: "http://example.com"}] = PII.detect_url("Visit http://example.com now")

    assert [%{value: "https://secure.example.com/path"}] =
             PII.detect_url("Visit https://secure.example.com/path")

    assert [%{value: "www.example.com"}] = PII.detect_url("Visit www.example.com")
    assert [%{value: "example.com/path"}] = PII.detect_url("Go to example.com/path")

    assert [%{value: "http://test.com"}, %{value: "https://example.org"}] =
             PII.detect_url("Visit http://test.com and https://example.org")

    assert [] = PII.detect_url("No URLs here.")
    assert [] = PII.detect_url("The word example.com in prose")
  end

  test "redact, mask, and hash strategies are type-aware" do
    assert sanitize(
             PII.new(type: :email, strategy: :redact),
             Message.user("Email test@example.com")
           ) =~ "[REDACTED_EMAIL]"

    assert sanitize(
             PII.new(type: :email, strategy: :mask),
             Message.user("Email user@example.com")
           ) =~ "user@****.com"

    assert sanitize(
             PII.new(type: :ip, strategy: :mask),
             Message.user("IP 192.168.1.100")
           ) =~ "*.*.*.100"

    assert sanitize(
             PII.new(type: :credit_card, strategy: :mask),
             Message.user("Card 4532015112830366")
           ) =~ "************0366"

    assert sanitize(
             PII.new(type: :email, strategy: :redact),
             Message.user("a@test.com b@test.com")
           )
           |> String.split("[REDACTED_EMAIL]")
           |> length() == 3

    hash_one =
      sanitize(PII.new(type: :email, strategy: :hash), Message.user("Email test@example.com"))

    hash_two =
      sanitize(PII.new(type: :email, strategy: :hash), Message.user("Email test@example.com"))

    assert hash_one == hash_two
    assert hash_one =~ ~r/<email_hash:[a-f0-9]{8}>/
    refute hash_one =~ "test@example.com"
  end

  test "block strategy returns a tagged BeamWeaver error with match context" do
    middleware = PII.new(type: :email, strategy: :block)

    assert {:error,
            %Error{
              type: :pii_detected,
              details: %{pii_type: "email", matches: [%{value: "test@example.com"}]}
            }} =
             PII.before_model(
               middleware,
               %{messages: [Message.user("Email test@example.com")]},
               nil
             )

    assert {:error, %Error{details: %{matches: [_, _]}}} =
             PII.before_model(
               middleware,
               %{messages: [Message.user("Email alice@test.com and bob@test.com")]},
               nil
             )
  end

  test "input processing only edits the last user message" do
    middleware = PII.new(type: :email, strategy: :redact)

    assert %{messages: %Overwrite{} = overwrite} =
             PII.before_model(
               middleware,
               %{
                 messages: [
                   Message.user("Old old@example.com"),
                   Message.assistant("ok"),
                   Message.user("New new@example.com")
                 ]
               },
               nil
             )

    assert {:ok, [old, _assistant, new]} = Overwrite.get(overwrite)
    assert old.content == "Old old@example.com"
    assert new.content == "New [REDACTED_EMAIL]"
  end

  test "output and tool-result scopes are independent" do
    output_only =
      PII.new(type: :email, strategy: :redact, apply_to_input: false, apply_to_output: true)

    tool_only =
      PII.new(type: :ip, strategy: :mask, apply_to_input: false, apply_to_tool_results: true)

    assert is_nil(
             PII.before_model(
               output_only,
               %{messages: [Message.user("Email test@example.com")]},
               nil
             )
           )

    assert %{messages: %Overwrite{} = output_update} =
             PII.after_model(
               output_only,
               %{messages: [Message.assistant("AI ai@example.com")]},
               nil
             )

    assert {:ok, [%Message{content: "AI [REDACTED_EMAIL]"}]} = Overwrite.get(output_update)

    messages = [
      Message.user("Get server IP"),
      Message.assistant("", tool_calls: [%{id: "call_1", name: "lookup"}]),
      Message.tool("Server IP: 192.168.1.100", tool_call_id: "call_1")
    ]

    assert %{messages: %Overwrite{} = tool_update} =
             PII.before_model(tool_only, %{messages: messages}, nil)

    assert {:ok, [_user, _assistant, %Message{role: :tool, content: "Server IP: *.*.*.100"}]} =
             Overwrite.get(tool_update)

    tool_block =
      PII.new(type: :email, strategy: :block, apply_to_input: false, apply_to_tool_results: true)

    assert {:error, %Error{type: :pii_detected, details: %{pii_type: "email"}}} =
             PII.before_model(
               tool_block,
               %{
                 messages: [
                   Message.user("lookup"),
                   Message.assistant("", tool_calls: [%{id: "call_2", name: "lookup"}]),
                   Message.tool("User email: sensitive@example.com", tool_call_id: "call_2")
                 ]
               },
               nil
             )
  end

  test "one middleware can process both input and output scopes" do
    both = PII.new(type: :email, strategy: :redact, apply_to_input: true, apply_to_output: true)

    assert sanitize(both, Message.user("Email test@example.com")) == "Email [REDACTED_EMAIL]"

    assert %{messages: %Overwrite{} = overwrite} =
             PII.after_model(
               both,
               %{messages: [Message.assistant("AI ai@example.com")]},
               nil
             )

    assert {:ok, [%Message{content: "AI [REDACTED_EMAIL]"}]} = Overwrite.get(overwrite)
    assert is_nil(PII.before_model(both, %{messages: [Message.user("No PII here")]}, nil))
    assert is_nil(PII.before_model(both, %{messages: []}, nil))
  end

  test "custom regex and callable detectors normalize values for all strategies" do
    regex = PII.new(type: "api_key", detector: "sk-[a-zA-Z0-9]{32}", strategy: :redact)

    assert "Key [REDACTED_API_KEY]" =
             sanitize(regex, Message.user("Key sk-abcdefghijklmnopqrstuvwxyz123456"))

    callable =
      PII.new(
        type: "indian_phone",
        detector: fn content ->
          Regex.scan(~r/\+91[\s.-]?\d{10}/, content, return: :index)
          |> Enum.map(fn [{start, length}] ->
            %{text: binary_part(content, start, length), start: start, end: start + length}
          end)
        end,
        strategy: :hash
      )

    content = sanitize(callable, Message.user("Call +91 9876543210"))
    assert content =~ ~r/<indian_phone_hash:[a-f0-9]{8}>/
    refute content =~ "+91 9876543210"

    masked =
      callable
      |> Map.put(:strategy, :mask)
      |> sanitize(Message.user("Call +91 9876543210"))

    assert masked =~ "****3210"
    refute masked =~ "+91 9876543210"

    confidential =
      PII.new(
        type: "confidential",
        detector: fn content ->
          case :binary.match(content, "CONFIDENTIAL") do
            {start, length} ->
              [%{type: "confidential", value: "CONFIDENTIAL", start: start, end: start + length}]

            :nomatch ->
              []
          end
        end,
        strategy: :redact
      )

    assert sanitize(confidential, Message.user("This is CONFIDENTIAL information")) ==
             "This is [REDACTED_CONFIDENTIAL] information"
  end

  test "multiple middleware rules can be applied sequentially" do
    message = Message.user("Email test@example.com, IP: 192.168.1.1")
    email = PII.new(type: :email, strategy: :redact)
    ip = PII.new(type: :ip, strategy: :mask)

    first = sanitize(email, message)
    second = sanitize(ip, %{message | content: first})

    assert second =~ "[REDACTED_EMAIL]"
    assert second =~ "*.*.*.1"
    refute second =~ "test@example.com"
    refute second =~ "192.168.1.1"
  end

  test "one custom detector can redact multiple PII types" do
    combined =
      PII.new(
        type: "email_or_ip",
        detector: fn content -> PII.detect_email(content) ++ PII.detect_ip(content) end,
        strategy: :redact
      )

    content = sanitize(combined, Message.user("Email: test@example.com, IP: 10.0.0.1"))

    refute content =~ "test@example.com"
    refute content =~ "10.0.0.1"
    assert content =~ "[REDACTED_EMAIL]"
    assert content =~ "[REDACTED_IP]"
  end

  test "unknown builtin type requires an explicit detector" do
    assert_raise ArgumentError, ~r/Unknown PII type/, fn ->
      PII.new(type: "unknown_type", strategy: :redact)
    end
  end

  test "strategy config is atom-only" do
    assert_raise ArgumentError, ~s(strategy must be an atom, got "redact"; use :redact), fn ->
      PII.new(type: :email, strategy: "redact")
    end
  end

  defp sanitize(middleware, message) do
    assert %{messages: %Overwrite{} = overwrite} =
             PII.before_model(middleware, %{messages: [message]}, nil)

    assert {:ok, [%Message{content: content}]} = Overwrite.get(overwrite)
    content
  end
end
