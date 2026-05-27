defmodule BeamWeaver.SerializationTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Adapter.ValueCodec
  alias BeamWeaver.Core.Document
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Send
  alias BeamWeaver.Serialization
  alias BeamWeaver.Serialization.Encrypted
  alias BeamWeaver.Serialization.Registry
  alias BeamWeaver.TimeoutPolicy
  alias BeamWeaver.Tracing.Run

  defmodule RegisteredAppStruct do
    defstruct [:id, :value]
  end

  test "round trips registered BeamWeaver structs through safe JSON tags" do
    value = %{
      document: %Document{id: "d1", content: "source text", metadata: %{source: "test"}},
      message: %Message{id: "m1", role: :assistant, content: "hello"},
      command: %Command{update: %{answer: 1}, goto: :done},
      send: %Send{node: :worker, update: %{item: "a"}, timeout: 250},
      send_with_policy: %Send{
        node: :policy_worker,
        update: %{item: "b"},
        timeout: TimeoutPolicy.new!(idle_timeout: 250, refresh_on: :heartbeat)
      },
      error: Error.new(:example, "failed", %{reason: :known}),
      run:
        Run.new("serializer",
          id: "run_1",
          trace_id: "trace_1",
          started_at: ~U[2026-05-22 00:00:00Z],
          metadata: %{provider: :openai}
        )
    }

    assert {:ok, encoded} = Serialization.dump(value)
    assert is_binary(encoded)
    assert {:ok, decoded} = Serialization.load(encoded)

    assert decoded["document"].id == "d1"
    assert decoded["document"].content == "source text"
    assert decoded["message"].id == "m1"
    assert decoded["message"].role == :assistant
    assert decoded["command"].goto == :done
    assert decoded["send"].node == :worker
    assert decoded["send"].timeout == 250
    assert decoded["send_with_policy"].node == :policy_worker

    assert %TimeoutPolicy{idle_timeout: 250, refresh_on: :heartbeat} =
             decoded["send_with_policy"].timeout

    assert decoded["error"].type == :example
    assert decoded["run"].id == "run_1"
    assert decoded["run"].started_at == ~U[2026-05-22 00:00:00Z]
    assert decoded["run"].metadata["provider"] == :openai
  end

  test "round trips portable scalar edge cases without public ETF loading" do
    value = %{
      binary: <<0, 1, 2, 255>>,
      tuple: {:ok, [:known, 1]},
      datetime: ~U[2026-05-22 12:00:00Z],
      naive_datetime: ~N[2026-05-22 12:00:00],
      date: ~D[2026-05-22],
      time: ~T[12:00:00]
    }

    assert {:ok, encoded} = Serialization.dump(value)
    refute :binary.match(encoded, <<131>>) != :nomatch
    assert {:ok, decoded} = Serialization.load(encoded)

    assert decoded["binary"] == <<0, 1, 2, 255>>
    assert decoded["tuple"] == {:ok, [:known, 1]}
    assert decoded["datetime"] == ~U[2026-05-22 12:00:00Z]
    assert decoded["naive_datetime"] == ~N[2026-05-22 12:00:00]
    assert decoded["date"] == ~D[2026-05-22]
    assert decoded["time"] == ~T[12:00:00]
  end

  test "rejects unregistered structs instead of arbitrary term loading" do
    assert {:error, %Error{type: :unsupported_serialization_type}} =
             Serialization.dump(%URI{scheme: "https", host: "example.com"})
  end

  test "escapes reserved type tags in plain user maps before decoding" do
    value = %{
      "__beam_weaver_type__" => "beam_weaver.core.message",
      "role" => "assistant",
      "content" => "this is plain user data",
      "nested" => %{
        "__beam_weaver_type__" => "beam_weaver.core.document",
        "content" => "also plain"
      }
    }

    assert {:ok, encoded} = Serialization.dump(value)
    assert encoded =~ ~s("__beam_weaver_type__":"map")

    assert {:ok, decoded} = Serialization.load(encoded)
    assert decoded == value
    refute match?(%Message{}, decoded)
    refute match?(%Document{}, decoded["nested"])
  end

  test "reserved type tags inside registered struct metadata remain plain data" do
    document =
      Document.new!("hello",
        metadata: %{
          "__beam_weaver_type__" => "beam_weaver.core.message",
          "content" => "not a message",
          "role" => "assistant"
        }
      )

    assert {:ok, encoded} = Serialization.dump(document)
    assert {:ok, decoded} = Serialization.load(encoded)

    assert %Document{} = decoded

    assert decoded.metadata == %{
             "__beam_weaver_type__" => "beam_weaver.core.message",
             "content" => "not a message",
             "role" => "assistant"
           }
  end

  test "LangChain-shaped secret dictionaries in user data never read environment values" do
    env_name = "BEAM_WEAVER_SECRET_INJECTION_TEST"
    env_value = "do-not-leak-#{System.unique_integer([:positive])}"
    System.put_env(env_name, env_value)

    on_exit(fn -> System.delete_env(env_name) end)

    malicious_secret = %{"lc" => 1, "type" => "secret", "id" => [env_name]}

    payload = %{
      "plain" => malicious_secret,
      "nested" => [%{"metadata" => malicious_secret}],
      "message" => Message.user("hello", metadata: %{secret_like: malicious_secret})
    }

    assert {:ok, encoded} = Serialization.dump(payload)
    refute encoded =~ env_value

    assert {:ok, decoded} = Serialization.load(encoded)
    assert decoded["plain"] == malicious_secret
    assert decoded["nested"] == [%{"metadata" => malicious_secret}]
    assert decoded["message"].metadata["secret_like"] == malicious_secret
    refute inspect(decoded) =~ env_value
  end

  test "foreign constructor and method-call shaped payloads stay inert plain data" do
    path =
      Path.join(
        System.tmp_dir!(),
        "beam_weaver_foreign_serde_#{System.unique_integer([:positive])}.txt"
      )

    File.write!(path, "secret-file-content")
    on_exit(fn -> File.rm(path) end)

    payload = %{
      "lc" => 2,
      "type" => "constructor",
      "id" => ["pathlib", "Path"],
      "method" => "read_text",
      "args" => [path],
      "kwargs" => %{}
    }

    assert {:ok, encoded} = BeamWeaver.JSON.encode(payload)
    assert {:ok, decoded} = Serialization.load(encoded)

    assert decoded == payload
    refute inspect(decoded) =~ "secret-file-content"
  end

  test "dump_value and load_value expose safe JSON-compatible data" do
    message = Message.user("hello", metadata: %{source: "unit"})

    assert {:ok, encoded} = Serialization.dump_value(message)
    assert encoded["__beam_weaver_type__"] == "beam_weaver.core.message"
    assert encoded["metadata"] == %{"source" => "unit"}

    assert {:ok, %Message{role: :user, content: "hello", metadata: %{"source" => "unit"}}} =
             Serialization.load_value(encoded)
  end

  test "rejects unknown struct tags, unknown atoms, corrupt JSON, and invalid base64" do
    assert {:error, %Error{type: :unsupported_serialization_type}} =
             Serialization.load(~s({"__beam_weaver_type__":"app.unknown","id":"x"}))

    assert {:error, %Error{type: :unsupported_serialization_type}} =
             Serialization.load(~s({"__beam_weaver_type__":"atom","value":"beam_weaver_missing_atom_for_test"}))

    assert {:error, %Error{type: :serialization_error}} = Serialization.load("{not-json")

    assert {:error, %Error{type: :serialization_error}} =
             Serialization.load(~s({"__beam_weaver_type__":"binary","base64":"%%%"}))
  end

  test "decodes registered application structs without atom creation from unknown fields" do
    registry =
      Registry.new()
      |> Registry.register("app.registered", RegisteredAppStruct)

    value = %RegisteredAppStruct{id: "item-1", value: %{answer: 42}}

    assert {:ok, encoded} = Serialization.dump(value, registry: registry)

    {:ok, decoded_json} = BeamWeaver.JSON.decode(encoded)

    payload =
      decoded_json
      |> Map.put("unknown_external_field", "ignored")
      |> BeamWeaver.JSON.encode!()

    assert {:ok, %RegisteredAppStruct{id: "item-1", value: %{"answer" => 42}}} =
             Serialization.load(payload, registry: registry)
  end

  test "registry allowlist includes curated core structs and blocks app structs until registered" do
    registry = Registry.new()
    assert "beam_weaver.core.document" in Registry.tags(registry)
    assert Registry.module_for(registry, "beam_weaver.core.message") == Message

    value = %RegisteredAppStruct{id: "blocked", value: "before-register"}

    assert {:error, %Error{type: :unsupported_serialization_type}} =
             Serialization.dump(value)

    allowed = Registry.register(registry, "app.registered", RegisteredAppStruct)
    assert {:ok, encoded} = Serialization.dump(value, registry: allowed)

    assert {:error, %Error{type: :unsupported_serialization_type}} =
             Serialization.load(encoded, registry: registry)

    assert {:ok, ^value} = Serialization.load(encoded, registry: allowed)
  end

  test "message registry tier allows messages and blocks other core structs" do
    message_registry = Registry.new(:messages)
    assert Registry.tags(message_registry) == ["beam_weaver.core.message"]

    message = Message.assistant("hello")
    document = Document.new!("secret")

    assert {:ok, encoded_message} = Serialization.dump(message)

    assert {:ok, %Message{content: "hello"}} =
             Serialization.load(encoded_message, registry: message_registry)

    assert {:ok, encoded_document} = Serialization.dump(document)

    assert {:error, %Error{type: :unsupported_serialization_type}} =
             Serialization.load(encoded_document, registry: message_registry)
  end

  test "adapter value codec shares the safe durable serialization boundary" do
    value = %{
      "message" => %Message{id: "m-codec", role: :tool, content: "done"},
      "tuple" => {:ok, [:known, 1]}
    }

    assert {:ok, encoded} = ValueCodec.dump(value)
    refute match?(<<131, _::binary>>, encoded)
    assert {:ok, decoded} = ValueCodec.load(encoded)

    assert decoded["message"].id == "m-codec"
    assert decoded["tuple"] == {:ok, [:known, 1]}
  end

  test "adapter value codec loads plain JSON rows and rejects corrupt tagged payloads" do
    assert {:ok, %{"plain" => [%{"value" => 1}]}} =
             ValueCodec.load_json_value(%{"plain" => [%{"value" => 1}]})

    corrupt = %{"__beam_weaver_type__" => "binary", "base64" => "%%%"}
    assert {:error, %Error{type: :serialization_error}} = ValueCodec.load_json_value(corrupt)
  end

  test "encrypted codec wraps safe JSON serialization with explicit AES-256-GCM keys" do
    key = :crypto.strong_rand_bytes(32)
    value = %{message: Message.user("secret"), tuple: {:ok, [:known]}}

    assert {:ok, encrypted} =
             Serialization.dump(value,
               serialization: [codec: Encrypted, encryption_key: key]
             )

    refute encrypted =~ "secret"

    assert {:ok, decoded} =
             Serialization.load(encrypted,
               serialization: [codec: Encrypted, encryption_key: key]
             )

    assert decoded["message"].content == "secret"
    assert decoded["tuple"] == {:ok, [:known]}

    assert {:ok, encrypted_with_base64_key} =
             Serialization.dump(value,
               serialization: [
                 codec: Encrypted,
                 encryption_key_base64: Base.encode64(key)
               ]
             )

    assert {:ok, decoded_with_base64_key} =
             Serialization.load(encrypted_with_base64_key,
               serialization: [
                 codec: Encrypted,
                 encryption_key_base64: Base.encode64(key)
               ]
             )

    assert decoded_with_base64_key["message"].content == "secret"
  end

  test "encrypted codec rejects missing, invalid, and wrong keys" do
    key = :crypto.strong_rand_bytes(32)

    assert {:error, %Error{type: :invalid_serialization_key}} =
             Serialization.dump(%{ok: true}, serialization: [codec: Encrypted])

    assert {:error, %Error{type: :invalid_serialization_key}} =
             Serialization.dump(%{ok: true},
               serialization: [codec: Encrypted, encryption_key: "short"]
             )

    {:ok, encrypted} =
      Serialization.dump(%{ok: true}, serialization: [codec: Encrypted, encryption_key: key])

    assert {:error, %Error{type: :serialization_error}} =
             Serialization.load(encrypted,
               serialization: [codec: Encrypted, encryption_key: :crypto.strong_rand_bytes(32)]
             )
  end

  test "encrypted codec propagates the inner serialization allowlist" do
    key = :crypto.strong_rand_bytes(32)

    registry =
      Registry.new()
      |> Registry.register("app.registered", RegisteredAppStruct)

    value = %RegisteredAppStruct{id: "secret", value: %{safe: true}}

    assert {:ok, encrypted} =
             Serialization.dump(value,
               serialization: [codec: Encrypted, encryption_key: key, registry: registry]
             )

    assert {:error, %Error{type: :unsupported_serialization_type}} =
             Serialization.load(encrypted,
               serialization: [codec: Encrypted, encryption_key: key]
             )

    assert {:ok, %RegisteredAppStruct{id: "secret", value: %{"safe" => true}}} =
             Serialization.load(encrypted,
               serialization: [codec: Encrypted, encryption_key: key, registry: registry]
             )
  end

  test "encrypted codec rejects plain payloads instead of running a legacy decode path" do
    key = :crypto.strong_rand_bytes(32)
    value = %{message: Message.user("legacy"), tuple: {:ok, [:plain]}}

    assert {:ok, plain} = Serialization.dump(value)

    assert {:error, %Error{type: :serialization_error}} =
             Serialization.load(plain, serialization: [codec: Encrypted, encryption_key: key])
  end

  test "encrypted codec keeps foreign constructor payloads inert after decrypting" do
    key = :crypto.strong_rand_bytes(32)

    path =
      Path.join(
        System.tmp_dir!(),
        "beam_weaver_encrypted_foreign_serde_#{System.unique_integer([:positive])}.txt"
      )

    File.write!(path, "encrypted-secret-file-content")
    on_exit(fn -> File.rm(path) end)

    payload = %{
      "lc" => 2,
      "type" => "constructor",
      "id" => ["pathlib", "Path"],
      "method" => "read_text",
      "args" => [path],
      "kwargs" => %{}
    }

    assert {:ok, encrypted} =
             Serialization.dump(payload, serialization: [codec: Encrypted, encryption_key: key])

    assert {:ok, decoded} =
             Serialization.load(encrypted, serialization: [codec: Encrypted, encryption_key: key])

    assert decoded == payload
    refute inspect(decoded) =~ "encrypted-secret-file-content"
  end
end
