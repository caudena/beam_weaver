defmodule BeamWeaver.SerializationTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias BeamWeaver.Agent.Subagent.AsyncTask
  alias BeamWeaver.Agent.Usage
  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Document
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.InvalidToolCall
  alias BeamWeaver.Core.Messages.ToolCall
  alias BeamWeaver.Core.Messages.ToolCallChunk
  alias BeamWeaver.Filesystem
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Execution.NodeOutput
  alias BeamWeaver.Graph.Execution.TaskRequest
  alias BeamWeaver.Graph.ExecutionInfo
  alias BeamWeaver.Graph.Interrupt
  alias BeamWeaver.Graph.Messages.Remove
  alias BeamWeaver.Graph.Overwrite
  alias BeamWeaver.Graph.Resume
  alias BeamWeaver.Graph.Send
  alias BeamWeaver.Google.Messages, as: GoogleMessages
  alias BeamWeaver.Serialization
  alias BeamWeaver.Serialization.Encrypted
  alias BeamWeaver.Serialization.Registry
  alias BeamWeaver.TimeoutPolicy
  alias BeamWeaver.Tracing.Run

  defmodule RegisteredAppStruct do
    defstruct [:id, :value]
  end

  defmodule RegisteredAppError do
    defexception [:message]
  end

  defmodule PlainJSON do
    # An inner codec that encrypts JSON text as it is given.
    def dump(json, _opts), do: {:ok, json}
    def load(json, opts), do: BeamWeaver.Serialization.JSON.load(json, opts)
  end

  test "round trips registered BeamWeaver structs through safe JSON tags" do
    value = %{
      document: %Document{id: "d1", content: "source text", metadata: %{source: "test"}},
      message: %Message{
        id: "m1",
        role: :assistant,
        content: "hello",
        tool_calls: [%ToolCall{id: "call-1", name: "lookup", args: %{"q" => "beam"}}],
        metadata: %{
          invalid_tool_calls: [
            %InvalidToolCall{id: "bad-1", name: "broken", args: "{", error: "invalid json"}
          ],
          tool_call_chunks: [%ToolCallChunk{id: "chunk-1", index: 0, name: "lookup"}]
        }
      },
      command: %Command{update: %{answer: 1}, goto: :done},
      send: %Send{node: :worker, update: %{item: "a"}, timeout: 250},
      send_with_policy: %Send{
        node: :policy_worker,
        update: %{item: "b"},
        timeout: TimeoutPolicy.new!(idle_timeout: 250, refresh_on: :heartbeat)
      },
      error: Error.new(:example, "failed", %{reason: :known}),
      file_data: %Filesystem.FileData{
        content: "agent notes",
        encoding: "utf-8",
        created_at: "2026-05-29T10:00:00Z",
        modified_at: "2026-05-29T10:01:00Z"
      },
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

    assert decoded.document.id == "d1"
    assert decoded.document.content == "source text"
    assert decoded.document.metadata == %{source: "test"}
    assert decoded.message.id == "m1"
    assert decoded.message.role == :assistant
    assert [%ToolCall{id: "call-1", name: "lookup", args: %{"q" => "beam"}}] = decoded.message.tool_calls
    assert [%InvalidToolCall{id: "bad-1"}] = decoded.message.metadata.invalid_tool_calls
    assert [%ToolCallChunk{id: "chunk-1"}] = decoded.message.metadata.tool_call_chunks
    assert decoded.command == value.command
    assert decoded.send == value.send
    assert decoded.send_with_policy.node == :policy_worker

    assert %TimeoutPolicy{idle_timeout: 250, refresh_on: :heartbeat} =
             decoded.send_with_policy.timeout

    assert decoded.error == value.error
    assert %Filesystem.FileData{content: "agent notes", encoding: "utf-8"} = decoded.file_data
    assert decoded.run.id == "run_1"
    assert decoded.run.started_at == ~U[2026-05-22 00:00:00Z]
    assert decoded.run.metadata == %{provider: :openai}
  end

  test "restored assistant tool-call content remains provider encodable" do
    message =
      Message.assistant(
        [
          %{
            type: :tool_call,
            id: "call-1",
            name: "lookup",
            args: %{"q" => "beam"},
            thought_signature: "sig-1"
          }
        ],
        tool_calls: [
          %ToolCall{
            id: "call-1",
            provider_id: "call-1",
            call_id: "call-1",
            name: "lookup",
            thought_signature: "sig-1",
            args: %{"q" => "beam"}
          }
        ]
      )

    assert {:ok, encoded} = Serialization.dump(message)
    assert {:ok, %Message{} = decoded} = Serialization.load(encoded)

    assert [%{type: :tool_call, id: "call-1", name: "lookup", args: %{"q" => "beam"}}] =
             decoded.content

    assert [%ToolCall{id: "call-1", thought_signature: "sig-1"}] = decoded.tool_calls

    assert {:ok,
            {nil,
             [
               %{
                 "parts" => [
                   %{
                     "functionCall" => %{
                       "name" => "lookup",
                       "args" => %{"q" => "beam"}
                     }
                   }
                 ]
               }
             ]}} = GoogleMessages.encode_messages([decoded])
  end

  test "round trips framework structs that can appear inside checkpoint state" do
    value = %{
      "channel_values" => %{
        "async_tasks" => %{
          "async-1" => %AsyncTask{
            id: "async-1",
            task_id: "async-1",
            subagent_name: "research",
            status: "running",
            updates: [%{message: "started"}]
          }
        },
        "execution_info" => %ExecutionInfo{
          checkpoint_id: "cp-1",
          checkpoint_ns: "",
          task_id: "task-1",
          thread_id: "thread-1",
          run_id: "run-1"
        },
        "messages" => [
          %Message{
            id: "assistant-1",
            role: :assistant,
            content: "",
            tool_calls: [%ToolCall{id: "call-1", name: "lookup", args: %{}}],
            artifacts: [ContentBlock.tool_result(content: "done", tool_call_id: "call-1")]
          }
        ]
      },
      "channel_deltas" => %{"messages" => [%Remove{id: "old-message"}]},
      "metadata" => %{
        "step_update" => %{
          "usage" => %Usage{
            input_tokens: 12,
            output_tokens: 3,
            total_tokens: 15,
            model_calls: 1
          }
        }
      },
      "next_tasks" => [
        TaskRequest.send(
          "worker",
          %{messages: [%Remove{id: "stale-message"}]},
          ["__tasks__"],
          timeout: 500
        )
      ],
      "interrupts" => [
        %Interrupt{
          id: "interrupt-1",
          task_id: "task-1",
          node: "worker",
          step: 1,
          value: %{action_requests: [%{name: "lookup", args: %{}}]},
          resumes: [%Resume{value: %{decisions: [%{type: "approve"}]}}]
        }
      ],
      "pending_writes" => [{"task-1", "messages", [%Remove{id: "pending-remove"}]}],
      # A graph node's output as a cache keeps it.
      "node_output" => %NodeOutput{
        raw: %Command{update: %{order: %{id: "A-1001"}}, goto: :notify},
        projected: %Command{update: %{order: %{id: "A-1001"}}, goto: :notify}
      },
      "command" => %Command{
        update: %{messages: %Overwrite{value: [Message.user("replacement")]}},
        goto: [%Send{node: :finish, update: %{done: true}}]
      }
    }

    assert {:ok, encoded} = Serialization.dump(value)
    assert {:ok, decoded} = Serialization.load(encoded)

    assert %AsyncTask{id: "async-1", status: "running"} =
             decoded["channel_values"]["async_tasks"]["async-1"]

    assert %ExecutionInfo{checkpoint_id: "cp-1", task_id: "task-1"} =
             decoded["channel_values"]["execution_info"]

    assert [%Message{tool_calls: [%ToolCall{id: "call-1"}]}] =
             decoded["channel_values"]["messages"]

    assert [%Remove{id: "old-message"}] = decoded["channel_deltas"]["messages"]

    assert %Usage{input_tokens: 12, output_tokens: 3, total_tokens: 15, model_calls: 1} =
             decoded["metadata"]["step_update"]["usage"]

    assert [%TaskRequest{node: "worker", kind: :send, timeout: 500}] = decoded["next_tasks"]
    assert [%Interrupt{id: "interrupt-1", resumes: [%Resume{}]}] = decoded["interrupts"]
    assert [{"task-1", "messages", [%Remove{id: "pending-remove"}]}] = decoded["pending_writes"]
    assert %Command{update: %{messages: %Overwrite{value: [%Message{}]}}} = decoded["command"]
    assert %Interrupt{value: %{action_requests: [%{name: "lookup", args: %{}}]}} = hd(decoded["interrupts"])
    assert decoded == value
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

    assert decoded == value
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

  test "secret dictionaries in user data never read environment values" do
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
    assert decoded["message"].metadata.secret_like == malicious_secret
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
    assert encoded["metadata"] == %{"source" => "unit", "__beam_weaver_atom_keys__" => true}

    assert {:ok, %Message{role: :user, content: "hello", metadata: %{source: "unit"}}} =
             Serialization.load_value(encoded)
  end

  @tag :capture_log
  test "a struct whose tag isn't registered loads as a map of its fields, with one warning per tag" do
    tag = "app.retired_order_#{System.unique_integer([:positive])}"

    json =
      ~s({"__beam_weaver_type__":"#{tag}","id":"A-1001","sent_at":{"__beam_weaver_type__":"date","value":"2026-10-17"}})

    expected = %{"id" => "A-1001", "sent_at" => ~D[2026-10-17]}

    log =
      capture_log(fn ->
        assert {:ok, [^expected, ^expected]} = Serialization.load("[#{json},#{json}]")
        assert {:ok, ^expected} = Serialization.load(json)
      end)

    assert [_one] = Regex.scan(~r/#{Regex.escape(tag)}/, log)
    assert log =~ "as a map of its fields"
  end

  @tag :capture_log
  test "a struct whose registered module is gone loads as a map of its fields" do
    registry = Registry.register(Registry.new(), "app.registered", __MODULE__.RemovedStruct)

    json =
      ~s({"__beam_weaver_type__":"app.registered","id":"A-1001","value":{"qty":2,"__beam_weaver_atom_keys__":true}})

    assert {:ok, %{"id" => "A-1001", "value" => %{qty: 2}}} = Serialization.load(json, registry: registry)
  end

  @tag :capture_log
  test "an atom that no loaded code uses loads as its name, with one warning per atom" do
    name = "retired_status_#{System.unique_integer([:positive])}"
    atom = %{"__beam_weaver_type__" => "atom", "value" => name}

    log =
      capture_log(fn ->
        assert {:ok, [^name, ^name]} = Serialization.load_value([atom, atom])
        assert {:ok, ^name} = Serialization.load_value(atom)
      end)

    assert [_one] = Regex.scan(~r/#{name}/, log)
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
  end

  @tag :capture_log
  test "an atom key that no loaded code uses loads as its name, with a warning" do
    name = "retired_field_#{System.unique_integer([:positive])}"

    log =
      capture_log(fn ->
        assert {:ok, %{^name => 1}} = Serialization.load_value(%{name => 1, "__beam_weaver_atom_keys__" => true})
      end)

    assert log =~ name
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
  end

  test "rejects corrupt JSON and invalid base64" do
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

    assert {:ok, %RegisteredAppStruct{id: "item-1", value: %{answer: 42}}} =
             Serialization.load(payload, registry: registry)
  end

  @tag :capture_log
  test "registry allowlist includes curated core structs and loads app structs only once registered" do
    registry = Registry.new()
    assert "beam_weaver.core.document" in Registry.tags(registry)
    assert Registry.module_for(registry, "beam_weaver.core.message") == Message

    value = %RegisteredAppStruct{id: "blocked", value: "before-register"}

    assert {:error, %Error{type: :unsupported_serialization_type}} =
             Serialization.dump(value)

    allowed = Registry.register(registry, "app.registered", RegisteredAppStruct)
    assert {:ok, encoded} = Serialization.dump(value, registry: allowed)

    assert {:ok, %{"id" => "blocked", "value" => "before-register"}} = Serialization.load(encoded, registry: registry)

    assert {:ok, ^value} = Serialization.load(encoded, registry: allowed)
  end

  @tag :capture_log
  test "message registry tier loads messages and other core structs as their fields" do
    message_registry = Registry.new(:messages)
    assert Registry.tags(message_registry) == ["beam_weaver.core.message"]

    message = Message.assistant("hello")
    document = Document.new!("secret")

    assert {:ok, encoded_message} = Serialization.dump(message)

    assert {:ok, %Message{content: "hello"}} =
             Serialization.load(encoded_message, registry: message_registry)

    assert {:ok, encoded_document} = Serialization.dump(document)
    assert {:ok, %{"content" => "secret"} = fields} = Serialization.load(encoded_document, registry: message_registry)
    refute is_struct(fields)
  end

  @tag :capture_log
  test "checkpoint-shaped payloads build only registered BeamWeaver structs and keep foreign constructors inert" do
    foreign_constructor = %{
      "lc" => 2,
      "type" => "constructor",
      "id" => ["pathlib", "Path"],
      "method" => "read_text",
      "args" => ["/tmp/secret"],
      "kwargs" => %{}
    }

    checkpoint_value = %{
      "channel_values" => %{"messages" => [foreign_constructor]},
      "pending_writes" => [
        [
          "task-1",
          "messages",
          %{"__beam_weaver_type__" => "beam_weaver.graph.messages.remove", "id" => "m-1"}
        ]
      ]
    }

    assert {:ok, decoded} = Serialization.load_value(checkpoint_value)
    assert decoded["channel_values"]["messages"] == [foreign_constructor]
    assert [["task-1", "messages", %Remove{id: "m-1"}]] = decoded["pending_writes"]

    unsafe =
      put_in(
        checkpoint_value,
        ["channel_values", "messages"],
        [%{"__beam_weaver_type__" => "beam_weaver.graph.unknown", "value" => %{}}]
      )

    assert {:ok, %{"channel_values" => %{"messages" => [%{"value" => %{}}]}}} = Serialization.load_value(unsafe)
  end

  test "adapters keep the encryption key of their serialization config without showing it" do
    key = :crypto.strong_rand_bytes(32)
    serialization = [codec: Encrypted, encryption_key: key]
    checkpointer = BeamWeaver.Checkpoint.Ecto.new(repo: NoRepo, serialization: serialization)
    cache = BeamWeaver.Cache.Ecto.new(repo: NoRepo, serialization: serialization)

    assert {:ok, sealed} = Serialization.dump(%{"card" => "4111"}, serialization: cache.serialization)
    refute sealed =~ "4111"
    assert {:ok, %{"card" => "4111"}} = Serialization.load(sealed, serialization: cache.serialization)

    assert {:ok, sealed} = Serialization.dump_value(%{"card" => "4111"}, serialization: checkpointer.serialization)
    assert %{"ciphertext" => _ciphertext} = sealed

    assert {:ok, %{"card" => "4111"}} =
             Serialization.load_value(sealed, serialization: checkpointer.serialization)

    refute inspect(checkpointer, limit: :infinity) =~ "encryption_key"
    refute inspect(cache, limit: :infinity) =~ "encryption_key"
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

    assert decoded == value

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

    assert decoded_with_base64_key == value
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

  @tag :capture_log
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

    assert {:ok, %{"id" => "secret", "value" => %{safe: true}}} =
             Serialization.load(encrypted,
               serialization: [codec: Encrypted, encryption_key: key]
             )

    assert {:ok, ^value} =
             Serialization.load(encrypted,
               serialization: [codec: Encrypted, encryption_key: key, registry: registry]
             )
  end

  @tag :capture_log
  test "encrypted codec loads a struct it can't rebuild and an atom that isn't loaded as plain data" do
    key = :crypto.strong_rand_bytes(32)
    name = "retired_status_#{System.unique_integer([:positive])}"

    json =
      ~s({"order":{"__beam_weaver_type__":"app.retired_order","id":"A-1001"},) <>
        ~s("status":{"__beam_weaver_type__":"atom","value":"#{name}"},"__beam_weaver_atom_keys__":true})

    assert {:ok, sealed} = Encrypted.dump(json, encryption_key: key, inner_codec: PlainJSON)

    assert {:ok, %{order: %{"id" => "A-1001"}, status: ^name}} =
             Serialization.load(sealed, serialization: [codec: Encrypted, encryption_key: key])
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

  describe "map keys" do
    test "load back as they were saved, at any depth and inside structs" do
      line = %{sku: "S-1", qty: 2}

      value = %{
        order: %{:id => "A-1001", :status => :open, :lines => [line], "gift_note" => "Happy birthday"},
        totals: %{1 => 40, 2 => 15.5},
        paid: %{true => ["A-1001"], false => [], nil => []},
        quantities: %{{:sku, "S-1"} => 2},
        raw: %{<<0, 255>> => "bytes"},
        message: Message.user("Refund order A-1001", metadata: %{order: line}),
        send: %Send{node: :refund, update: %{request: %{line: line}}},
        interrupt: %Interrupt{id: "interrupt-1", value: %{question: "Refund this line?", line: line}},
        command: %Command{update: %{refunds: [line]}, goto: :notify}
      }

      assert {:ok, json} = Serialization.dump(value)
      assert {:ok, ^value} = Serialization.load(json)
    end

    test "stay JSON object keys, and the object names its atom keys" do
      assert {:ok, %{"id" => "A-1001", "__beam_weaver_atom_keys__" => true}} =
               Serialization.dump_value(%{id: "A-1001"})

      assert {:ok, %{"id" => "A-1001", "gift_note" => "Hi", "__beam_weaver_atom_keys__" => ["id"]}} ==
               Serialization.dump_value(%{:id => "A-1001", "gift_note" => "Hi"})

      assert {:ok, %{"id" => "A-1001"}} == Serialization.dump_value(%{"id" => "A-1001"})

      # Integer keys can't be JSON object keys: the map is saved as entries.
      assert {:ok, %{"__beam_weaver_type__" => "map", "entries" => [%{"key" => 1, "value" => 40}]}} ==
               Serialization.dump_value(%{1 => 40})
    end

    test "whose atom doesn't exist load as strings, without creating the atom" do
      name = "retired_field_#{System.unique_integer([:positive])}"

      object = %{"id" => "A-1001", name => 1, "__beam_weaver_atom_keys__" => true}
      assert {:ok, %{:id => "A-1001", ^name => 1}} = Serialization.load_value(object)

      entries = %{
        "__beam_weaver_type__" => "map",
        "entries" => [%{"key" => %{"__beam_weaver_type__" => "atom", "value" => name}, "value" => 1}]
      }

      assert {:ok, %{^name => 1}} = Serialization.load_value(entries)
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    test "saved before keys kept their type load as strings, as before" do
      json = ~s({"order":{"id":"A-1001","status":{"__beam_weaver_type__":"atom","value":"open"}}})
      assert {:ok, %{"order" => %{"id" => "A-1001", "status" => :open}}} = Serialization.load(json)
    end

    test "named like the atom key marker stay plain data" do
      value = %{:id => "A-1001", "__beam_weaver_atom_keys__" => ["id"]}
      assert {:ok, json} = Serialization.dump(value)
      assert {:ok, ^value} = Serialization.load(json)

      value = %{__beam_weaver_atom_keys__: true}
      assert {:ok, json} = Serialization.dump(value)
      assert {:ok, ^value} = Serialization.load(json)
    end

    test "never include an atom __struct__, so stored data can't name a struct of its own" do
      file_stream = %{
        "__struct__" => %{"__beam_weaver_type__" => "atom", "value" => "Elixir.File.Stream"},
        "path" => "/etc/hosts",
        "modes" => [],
        "raw" => true,
        "line_or_bytes" => %{"__beam_weaver_type__" => "atom", "value" => "line"},
        "node" => %{"__beam_weaver_type__" => "atom", "value" => "nonode@nohost"}
      }

      for marker <- [true, ["__struct__", "line_or_bytes"]] do
        object = Map.put(file_stream, "__beam_weaver_atom_keys__", marker)

        assert {:error, %Error{type: :serialization_error, message: "encoded map has a __struct__ key"}} =
                 Serialization.load_value(object)

        assert {:error, %Error{type: :serialization_error}} =
                 Serialization.load_value(%{"state" => %{"doc" => [object]}})
      end

      uri = %{
        "__beam_weaver_type__" => "map",
        "entries" => [
          %{
            "key" => %{"__beam_weaver_type__" => "atom", "value" => "__struct__"},
            "value" => %{"__beam_weaver_type__" => "atom", "value" => "Elixir.URI"}
          },
          %{"key" => %{"__beam_weaver_type__" => "atom", "value" => "host"}, "value" => "evil.example"}
        ]
      }

      assert {:error, %Error{type: :serialization_error}} = Serialization.load_value(uri)

      # As a string key, without the marker, it is plain data.
      assert {:ok, %{"__struct__" => "Elixir.URI", host: "example.com"}} =
               Serialization.load_value(%{
                 "__struct__" => "Elixir.URI",
                 "host" => "example.com",
                 "__beam_weaver_atom_keys__" => ["host"]
               })

      # A plain map named like an exception's fields loads back as it was.
      value = %{__exception__: true, message: "not an exception"}
      assert {:ok, json} = Serialization.dump(value)
      assert {:ok, ^value} = Serialization.load(json)
    end
  end

  test "a registered exception takes __exception__ from its module, not from the stored data" do
    registry = Registry.new() |> Registry.register("app.registered_error", RegisteredAppError)

    assert {:ok, json} = Serialization.dump(%RegisteredAppError{message: "boom"}, registry: registry)
    assert {:ok, %RegisteredAppError{message: "boom"} = error} = Serialization.load(json, registry: registry)
    assert is_exception(error)

    tampered = json |> BeamWeaver.JSON.decode!() |> Map.put("__exception__", false) |> BeamWeaver.JSON.encode!()
    assert {:ok, %RegisteredAppError{__exception__: true} = error} = Serialization.load(tampered, registry: registry)
    assert is_exception(error)
  end

  test "an invalid encoded atom, tuple, binary or date is an error, not an exception" do
    for json <- [
          ~s({"__beam_weaver_type__":"atom","value":1}),
          ~s({"__beam_weaver_type__":"atom"}),
          ~s({"__beam_weaver_type__":"tuple","items":1}),
          ~s({"__beam_weaver_type__":"binary","base64":1}),
          ~s({"__beam_weaver_type__":"datetime"}),
          ~s({"__beam_weaver_type__":"date","value":20261017}),
          ~s({"__beam_weaver_type__":"map","entries":[{"key":{"__beam_weaver_type__":"atom","value":["__struct__"]},"value":1}]})
        ] do
      assert {:error, %Error{type: :serialization_error}} = Serialization.load(json)
    end
  end

  test "dump errors on a map with colliding atom and string keys instead of dropping one" do
    assert {:error, %Error{type: :unsupported_serialization_type}} =
             Serialization.dump(%{:a => 1, "a" => 2})
  end

  test "dump still succeeds for a map without key collisions" do
    assert {:ok, encoded} = Serialization.dump(%{:a => 1, "b" => 2})
    assert {:ok, decoded} = Serialization.load(encoded)
    assert decoded == %{:a => 1, "b" => 2}
  end
end
