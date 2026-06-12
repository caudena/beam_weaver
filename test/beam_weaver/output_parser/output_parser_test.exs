defmodule BeamWeaver.OutputParserTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages
  alias BeamWeaver.Core.Messages.InvalidToolCall
  alias BeamWeaver.OutputParser
  alias BeamWeaver.Runnable

  defmodule Answer do
    defstruct [:answer, :score]
  end

  defmodule FunctionArgs do
    defstruct [:name, :age]

    def schema do
      %{
        "type" => "object",
        "required" => ["name", "age"],
        "properties" => %{"name" => %{"type" => "string"}, "age" => %{"type" => "integer"}}
      }
    end
  end

  defmodule DogArgs do
    defstruct [:species]

    def schema do
      %{
        "type" => "object",
        "required" => ["species"],
        "properties" => %{"species" => %{"type" => "string"}}
      }
    end
  end

  test "string parser extracts text from messages" do
    message =
      Message.assistant([
        %{"type" => "text", "text" => "hello "},
        %{"type" => "unknown", "value" => 1},
        %{"type" => "text", "text" => "world"}
      ])

    assert {:ok, "hello world"} = Runnable.invoke(OutputParser.string(), message)
  end

  test "string parser transforms text and message streams chunk by chunk" do
    assert {:ok, chunks} =
             Runnable.transform(OutputParser.string(), [
               "one",
               Message.assistant("two"),
               %Messages.Chunk{content: "three"}
             ])

    assert Enum.to_list(chunks) == ["one", "two", "three"]

    assert {:ok, async_chunks} =
             OutputParser.string()
             |> Runnable.async_transform(["a", "b"])
             |> BeamWeaver.Core.Async.await()

    assert Enum.to_list(async_chunks) == ["a", "b"]
  end

  test "json parser supports full and partial JSON parsing" do
    assert {:ok, %{"answer" => 42}} =
             Runnable.invoke(OutputParser.json(), ~s({"answer":42}))

    assert {:ok, [%{"answer" => 42}]} =
             Runnable.invoke(OutputParser.json(), ~s([{"answer":42}]))

    assert {:ok, %{"answer" => 42}} =
             Runnable.invoke(OutputParser.json(partial: true), ~s({"answer":42}\ntrailing text))

    assert {:error, %Error{type: :output_parser_error, details: %{parser: :json_parser}}} =
             Runnable.invoke(OutputParser.json(), "not-json")
  end

  test "json parser recovers common partial JSON shapes from upstream tests" do
    cases = [
      {~s({"foo": "bar", "bar": "foo"}), %{"foo" => "bar", "bar" => "foo"}},
      {~s({"foo": "bar", "bar": "foo), %{"foo" => "bar", "bar" => "foo"}},
      {~s({"foo": "bar", "bar": "foo}), %{"foo" => "bar", "bar" => "foo}"}},
      {~s({"foo": "bar", "bar": "foo[), %{"foo" => "bar", "bar" => "foo["}},
      {~s({"foo": "bar", "bar": "foo\\), %{"foo" => "bar", "bar" => "foo"}},
      {~s({"foo": "bar", "bar":), %{"foo" => "bar"}},
      {~s({"foo": "bar", "bar"), %{"foo" => "bar"}},
      {~s({"foo": "bar", ), %{"foo" => "bar"}},
      {~s({"foo":"bar\\), %{"foo" => "bar"}}
    ]

    for {input, expected} <- cases do
      assert {:ok, ^expected} = OutputParser.parse_partial(OutputParser.json(), input)
    end
  end

  test "json parser handles unicode, Python-like dicts, and deterministic diff streams" do
    assert {:ok, %{"answer" => "λ", "flag" => true, "none" => nil}} =
             Runnable.invoke(OutputParser.json(), "{'answer':'λ','flag':True,'none':None}")

    assert {:ok, stream} =
             Runnable.stream(OutputParser.json(partial: true, diff: true), [
               ~s({"answer":1}),
               ~s({"answer":2})
             ])

    assert Enum.to_list(stream) == [
             %{"answer" => 1},
             [
               %{
                 "op" => "replace",
                 "path" => "",
                 "value" => %{"answer" => 2},
                 "old" => %{"answer" => 1}
               }
             ]
           ]
  end

  test "json parser streams partial parsed values only after valid JSON boundaries" do
    assert {:ok, stream} =
             Runnable.stream(OutputParser.json(partial: true), [
               ~s({"answer":),
               "42",
               "}",
               "\ntrailing text"
             ])

    assert Enum.to_list(stream) == [%{}, %{"answer" => 42}]
  end

  test "json parser handles fenced JSON code blocks and partial fenced output" do
    assert {:ok, %{"name" => "Ada"}} =
             Runnable.invoke(OutputParser.json(), """
             here is the json:
             ```json
             {"name":"Ada"}
             ```
             """)

    assert {:ok, %{"name" => "Ada"}} =
             Runnable.invoke(OutputParser.json(partial: true), """
             ```json
             {"name":"Ada"}
             ```
             trailing text
             """)
  end

  test "json parser handles nested escaped quotes and text around fenced JSON" do
    assert {:ok, %{"action" => "Final Answer", "action_input" => ~s({"foo": "bar"})}} =
             Runnable.invoke(
               OutputParser.json(),
               """
               Thought before
               ```json
               {"action":"Final Answer","action_input":"{\\"foo\\": \\"bar\\"}"}
               ```
               text after
               """
             )

    assert {:ok, %{"foo" => "bar"}} =
             Runnable.invoke(OutputParser.json(partial: true), """
             Here is a response:
             ```json
             {"foo": "bar"
             """)
  end

  test "json utility facade parses markdown partial JSON and checks required keys" do
    # Upstream reference:
    assert {:ok, %{"name" => "Ada"}} =
             OutputParser.parse_json_markdown("""
             ```json
             {"name": "Ada"
             ```
             """)

    assert {:ok, %{"name" => "Ada", "score" => 7}} =
             OutputParser.parse_and_check_json_markdown(~s({"name":"Ada","score":7}), [
               :name,
               "score"
             ])

    assert {:error, %Error{type: :output_parser_error, details: %{missing: ["score"]}}} =
             OutputParser.parse_and_check_json_markdown(~s({"name":"Ada"}), ["score"])

    assert {:ok, %{"action_input" => "line\nnext"}} =
             OutputParser.parse_partial_json(~s({"action_input": "line\nnext"}))
  end

  test "list parser handles comma and markdown bullet formats" do
    assert {:ok, ["alpha"]} = Runnable.invoke(OutputParser.list(), "alpha")

    assert {:ok, ["alpha", "beta", "gamma"]} =
             Runnable.invoke(OutputParser.list(), "- alpha\n- beta\n3. gamma")

    assert {:ok, ["one", "two", "three"]} =
             Runnable.invoke(OutputParser.list(separator: "|"), "one| two |three")

    assert {:ok, ["alpha", "beta"]} =
             Runnable.invoke(OutputParser.markdown_list(), "intro\n- alpha\n* beta\nplain")

    assert {:ok, ["apple", "banana", "cherry"]} =
             Runnable.invoke(
               OutputParser.list(),
               "Items:\n\n1. apple\n\n    2. banana\n\n3. cherry"
             )

    assert {:ok, []} = Runnable.invoke(OutputParser.markdown_list(), "No items in the list.")
  end

  test "list parser supports numbered lists and stream transforms" do
    assert {:ok, ["alpha", "beta"]} =
             Runnable.invoke(OutputParser.numbered_list(), "1. alpha\n2. beta\n- ignored")

    assert {:ok, ["alpha", "beta, with comma", "gamma"]} =
             Runnable.invoke(
               OutputParser.comma_separated_list(),
               ~s(alpha,"beta, with comma",gamma)
             )

    assert OutputParser.get_format_instructions(OutputParser.numbered_list()) =~ "numbered list"
    assert OutputParser.get_format_instructions(OutputParser.markdown_list()) =~ "Markdown list"
    assert OutputParser.get_format_instructions(OutputParser.comma_separated_list()) =~ "comma"

    assert {:ok, stream} =
             Runnable.transform(OutputParser.markdown_list(), ["- alpha\n", "- beta\n"])

    assert Enum.to_list(stream) == [["alpha"], ["beta"]]

    assert {:ok, spec} = Runnable.to_spec(OutputParser.numbered_list())
    assert {:ok, restored} = Runnable.from_spec(spec)
    assert {:ok, ["one", "two"]} = Runnable.invoke(restored, "1. one\n2. two")
  end

  test "csv and xml parsers handle common structured outputs" do
    assert {:ok, [["name", "title"], ["Ada", "compiler, pioneer"]]} =
             Runnable.invoke(OutputParser.csv(), "name,title\nAda,\"compiler, pioneer\"")

    assert {:ok,
            %{
              name: "root",
              text: "hello",
              children: [%{name: "child", text: "hello", children: []}]
            }} = Runnable.invoke(OutputParser.xml(), "<root><child>hello</child></root>")

    assert {:ok, %{name: "body", text: "Text of the body.", children: []}} =
             Runnable.invoke(OutputParser.xml(), """
             <?xml version="1.0" encoding="UTF-8"?>
             <body>Text of the body.</body>
             """)

    assert {:ok, %{name: "foo", children: [%{name: "bar"} | _rest]}} =
             Runnable.invoke(OutputParser.xml(), """
             Some random text
             ```xml
             <?xml version="1.0" encoding="UTF-8"?>
             <foo><bar><baz></baz><baz>slim.shady</baz></bar><baz>tag</baz></foo>
             ```
             More random text
             """)

    for invalid <- ["foo></foo>", "<foo></foo", "foo></foo", "foofoo"] do
      assert {:error, %Error{type: :output_parser_error, details: %{parser: :xml_parser}}} =
               Runnable.invoke(OutputParser.xml(), invalid)
    end
  end

  test "xml parser handles attributes self-closing nodes and rejects entity payloads" do
    # Upstream reference:
    assert {:ok,
            %{
              name: "root",
              attributes: %{"id" => "r1"},
              children: [
                %{name: "empty", attributes: %{"flag" => "yes"}, children: [], text: ""},
                %{name: "body", text: "kept"}
              ]
            }} =
             Runnable.invoke(
               OutputParser.xml(),
               ~s(<root id="r1"><empty flag="yes"/><body>kept</body></root>)
             )

    malicious = """
    <?xml version="1.0"?>
    <!DOCTYPE lolz [<!ENTITY lol "lol">]>
    <lolz>&lol;</lolz>
    """

    assert {:error, %Error{type: :output_parser_error, details: %{parser: :xml_parser}}} =
             Runnable.invoke(OutputParser.xml(), malicious)
  end

  test "xml parser transform and Task-backed parsing follow native stream semantics" do
    # Upstream reference:
    input = "<foo><bar><baz></baz><baz>slim.shady</baz></bar><baz>tag</baz></foo>"

    assert {:ok, chunks} = Runnable.transform(OutputParser.xml(), String.graphemes(input))

    assert [
             %{name: "foo", children: [%{name: "bar"}]},
             %{name: "foo", children: [%{name: "baz", text: "tag"}]}
           ] = Enum.to_list(chunks)

    assert {:ok, root_only_chunks} =
             Runnable.transform(
               OutputParser.xml(),
               String.graphemes("<?xml version=\"1.0\"?><body>Text of the body.</body>")
             )

    assert [%{name: "body", text: "Text of the body.", children: []}] =
             Enum.to_list(root_only_chunks)

    assert {:ok, %{name: "foo"}} =
             OutputParser.xml()
             |> OutputParser.async_parse(input)
             |> BeamWeaver.Core.Async.await()

    assert {:ok, async_chunks} =
             OutputParser.xml()
             |> Runnable.async_transform(String.graphemes(input))
             |> BeamWeaver.Core.Async.await()

    assert Enum.count(async_chunks) == 2
  end

  test "parse_result uses the first generation-like value and parser specs round-trip" do
    # Upstream reference:
    assert {:ok, "first"} =
             OutputParser.parse_result(
               OutputParser.string(),
               [Message.assistant("first"), Message.assistant("second")]
             )

    parsers = [
      {OutputParser.csv(separator: "|"), "a|b\nc|d", [["a", "b"], ["c", "d"]]},
      {OutputParser.xml(), "<root><child>ok</child></root>",
       %{name: "root", text: "ok", children: [%{name: "child", text: "ok", children: []}]}},
      {OutputParser.schema(%{"type" => "object", "required" => ["name"]}), ~s({"name":"Ada"}), %{"name" => "Ada"}}
    ]

    for {parser, input, expected} <- parsers do
      assert {:ok, spec} = Runnable.to_spec(parser)
      assert {:ok, restored} = Runnable.from_spec(spec)
      assert {:ok, ^expected} = Runnable.invoke(restored, input)
    end

    assert {:error, %Error{type: :unsupported_runnable_spec}} =
             Runnable.to_spec(OutputParser.schema(%{"type" => "object"}, as: Answer))
  end

  test "parser base facade supports prompt-aware and Task-backed parsing" do
    assert {:ok, %{"answer" => 42}} =
             OutputParser.parse_with_prompt(OutputParser.json(), ~s({"answer":42}), "ignored")

    assert {:ok, %{"answer" => 42}} =
             OutputParser.json()
             |> OutputParser.async_parse(~s({"answer":42}))
             |> BeamWeaver.Core.Async.await()

    assert {:ok, %{"answer" => 42}} =
             OutputParser.json()
             |> OutputParser.async_parse_result([~s({"answer":42})])
             |> BeamWeaver.Core.Async.await()

    assert {:ok, %{"answer" => 42}} =
             OutputParser.json()
             |> OutputParser.async_parse_with_prompt(~s({"answer":42}), "ignored")
             |> BeamWeaver.Core.Async.await()
  end

  test "OpenAI tools parser decodes tool call args" do
    message =
      Message.assistant("",
        tool_calls: [
          %{id: "call_1", name: "search", args: ~s({"query":"beam"})},
          %{"id" => "call_2", "name" => "lookup", "args" => %{"id" => 7}}
        ]
      )

    assert {:ok,
            [
              %{id: "call_1", name: "search", args: %{"query" => "beam"}},
              %{id: "call_2", name: "lookup", args: %{"id" => 7}}
            ]} = Runnable.invoke(OutputParser.openai_tools(), message)
  end

  test "OpenAI tools parser handles nested function-call shapes and invalid JSON arguments" do
    calls = [
      %{
        "id" => "call_1",
        "function" => %{"name" => "search", "arguments" => ~s({"query":"beam"})}
      },
      %{
        "id" => "call_2",
        "function" => %{"name" => "echo", "arguments" => "not-json"}
      },
      %{
        "id" => "call_3",
        "function" => %{"name" => "noop", "arguments" => nil}
      }
    ]

    assert {:ok,
            [
              %{id: "call_1", name: "search", args: %{"query" => "beam"}},
              %{
                id: "call_2",
                name: "echo",
                args: %InvalidToolCall{args: "not-json", error: "arguments were not valid JSON"}
              },
              %{id: "call_3", name: "noop", args: %{}}
            ]} = Runnable.invoke(OutputParser.openai_tools(), calls)
  end

  test "OpenAI tools parser supports first_only, return_id, key filters, and chunks" do
    calls = [
      %{id: "call_1", name: "search", args: ~s({"query":"beam"})},
      %{id: "call_2", name: "lookup", args: ~s({"id":7})}
    ]

    assert {:ok, %{name: "search", args: %{"query" => "beam"}}} =
             Runnable.invoke(
               OutputParser.openai_tools(first_only: true, return_id: false),
               calls
             )

    assert {:ok, [%{id: "call_2", name: "lookup", args: %{"id" => 7}}]} =
             Runnable.invoke(OutputParser.openai_tools(key_name: "lookup"), calls)

    chunk = %BeamWeaver.Core.Messages.AIChunk{
      tool_call_chunks: [
        %BeamWeaver.Core.Messages.ToolCallChunk{id: "call_3", name: "echo", args: ~s({"x":1})}
      ]
    }

    assert {:ok, [%{id: "call_3", name: "echo", args: %{"x" => 1}}]} =
             Runnable.invoke(OutputParser.openai_tools(), chunk)
  end

  test "OpenAI tools parser covers no-match, multi-match, empty, and empty-argument cases" do
    calls = [
      %{id: "call_other", name: "other", args: ~s({"b":2})},
      %{id: "call_func1", name: "func", args: ~s({"a":1})},
      %{id: "call_func2", name: "func", args: ~s({"a":3})}
    ]

    assert {:ok, nil} =
             Runnable.invoke(
               OutputParser.openai_tools(key_name: "missing", first_only: true),
               calls
             )

    assert {:ok, []} =
             Runnable.invoke(OutputParser.openai_tools(key_name: "missing"), calls)

    assert {:ok, %{id: "call_func1", name: "func", args: %{"a" => 1}}} =
             Runnable.invoke(OutputParser.openai_tools(key_name: "func", first_only: true), calls)

    assert {:ok, %{"a" => 1}} =
             Runnable.invoke(
               OutputParser.openai_tools(key_name: "func", first_only: true, return_id: false),
               calls
             )

    assert {:ok,
            [
              %{id: "call_func1", name: "func", args: %{"a" => 1}},
              %{id: "call_func2", name: "func", args: %{"a" => 3}}
            ]} = Runnable.invoke(OutputParser.openai_tools(key_name: "func"), calls)

    assert {:ok, [%{"a" => 1}, %{"a" => 3}]} =
             Runnable.invoke(OutputParser.openai_tools(key_name: "func", return_id: false), calls)

    assert {:ok, []} = Runnable.invoke(OutputParser.openai_tools(), [])

    assert {:ok, [%{id: "call_empty", name: "getStatus", args: %{}}]} =
             Runnable.invoke(OutputParser.openai_tools(), [
               %{"id" => "call_empty", "function" => %{"name" => "getStatus", "arguments" => ""}}
             ])

    assert {:ok, [%{id: "call_none", name: "orderStatus", args: %{}}]} =
             Runnable.invoke(OutputParser.openai_tools(), [
               %{
                 "id" => "call_none",
                 "function" => %{"name" => "orderStatus", "arguments" => nil}
               }
             ])

    assert {:ok, []} =
             Runnable.invoke(OutputParser.openai_tools(partial: true), [
               %{
                 "id" => "call_partial_none",
                 "function" => %{"name" => "streamingTool", "arguments" => nil}
               }
             ])
  end

  test "OpenAI tools parser streams accumulated partial tool-call chunks" do
    chunks = [
      Messages.ai_chunk(""),
      Messages.ai_chunk("",
        tool_call_chunks: [
          Messages.tool_call_chunk(id: "call_names", index: 0, name: "NameCollector", args: "")
        ]
      ),
      Messages.ai_chunk("",
        tool_call_chunks: [Messages.tool_call_chunk(index: 0, args: ~s({"na))]
      ),
      Messages.ai_chunk("",
        tool_call_chunks: [Messages.tool_call_chunk(index: 0, args: ~s(mes": ["suz))]
      ),
      Messages.ai_chunk("",
        tool_call_chunks: [Messages.tool_call_chunk(index: 0, args: ~s(y", "alex"]}))]
      )
    ]

    assert {:ok, stream} = Runnable.stream(OutputParser.openai_tools(), chunks)

    assert Enum.to_list(stream) == [
             [],
             [%{id: "call_names", name: "NameCollector", args: %{}}],
             [%{id: "call_names", name: "NameCollector", args: %{"names" => ["suz"]}}],
             [
               %{
                 id: "call_names",
                 name: "NameCollector",
                 args: %{"names" => ["suzy", "alex"]}
               }
             ]
           ]

    assert {:ok, async_stream} =
             OutputParser.openai_tools()
             |> Runnable.async_stream(chunks)
             |> BeamWeaver.Core.Async.await()

    assert async_stream |> Enum.to_list() |> List.last() == [
             %{
               id: "call_names",
               name: "NameCollector",
               args: %{"names" => ["suzy", "alex"]}
             }
           ]
  end

  test "OpenAI functions parser returns the first function call" do
    assert {:ok, %{name: "lookup", args: %{"id" => 7}}} =
             Runnable.invoke(OutputParser.openai_functions(), %{
               "function_call" => %{"name" => "lookup", "arguments" => ~s({"id":7})}
             })

    assert {:ok, %{"id" => 7}} =
             Runnable.invoke(OutputParser.openai_functions(args_only: true), %{
               "function_call" => %{"name" => "lookup", "arguments" => ~s({"id":7})}
             })

    assert {:ok, 7} =
             Runnable.invoke(OutputParser.openai_functions(key_name: "id"), %{
               "function_call" => %{"name" => "lookup", "arguments" => ~s({"id":7})}
             })

    assert {:ok, nil} =
             Runnable.invoke(
               OutputParser.openai_functions(required: false),
               Message.assistant("none")
             )

    assert {:ok, [%{name: "lookup", args: %{"id" => 7}}]} =
             Runnable.invoke(
               OutputParser.openai_functions(first_only: false),
               [%{"function" => %{"name" => "lookup", "arguments" => ~s({"id":7})}}]
             )

    assert {:ok, [%{"id" => 7}]} =
             Runnable.invoke(
               OutputParser.openai_functions(first_only: false, args_only: true),
               [%{"function" => %{"name" => "lookup", "arguments" => ~s({"id":7})}}]
             )
  end

  test "OpenAI functions parser handles malformed partial and keyed arguments" do
    assert {:error,
            %Error{
              type: :output_parser_error,
              details: %{parser: :openai_functions_parser}
            }} =
             Runnable.invoke(OutputParser.openai_functions(), %{
               "function_call" => %{"name" => "bad", "arguments" => "not-json"}
             })

    assert {:ok, %{"id" => 7}} =
             Runnable.invoke(OutputParser.openai_functions(args_only: true, partial: true), %{
               "function_call" => %{"name" => "lookup", "arguments" => ~s({"id":7)}
             })

    assert {:ok, nil} =
             Runnable.invoke(OutputParser.openai_functions(key_name: "missing", partial: true), %{
               "function_call" => %{"name" => "lookup", "arguments" => ~s({"id":7})}
             })

    assert {:error,
            %Error{
              type: :output_parser_error,
              details: %{parser: :openai_functions_parser, key: "missing"}
            }} =
             Runnable.invoke(OutputParser.openai_functions(key_name: "missing"), %{
               "function_call" => %{"name" => "lookup", "arguments" => ~s({"id":7})}
             })

    assert {:error, %Error{type: :output_parser_error, details: %{parser: :openai_functions_parser}}} =
             Runnable.invoke(
               OutputParser.openai_functions(),
               Message.user("not an assistant call")
             )
  end

  test "OpenAI functions parser matches strict and non-strict function argument parsing" do
    raw_newline_args = "{\"code\": \"print(2+\n2)\"}"

    assert {:ok, %{"code" => "print(2+\n2)"}} =
             Runnable.invoke(OutputParser.openai_functions(args_only: true), %{
               "function_call" => %{"name" => "run_code", "arguments" => raw_newline_args}
             })

    assert {:error, %Error{type: :output_parser_error, details: %{parser: :openai_functions_parser}}} =
             Runnable.invoke(OutputParser.openai_functions(args_only: true, strict: true), %{
               "function_call" => %{"name" => "run_code", "arguments" => raw_newline_args}
             })

    assert {:ok, %{"text" => "你好)"}} =
             Runnable.invoke(OutputParser.openai_functions(args_only: true), %{
               "function_call" => %{"name" => "unicode", "arguments" => ~s|{"text":"你好)"}|}
             })
  end

  test "OpenAI functions parser raises tagged errors for missing or malformed calls" do
    for bad_input <- [
          Message.user("not an assistant call"),
          Message.assistant("no function call"),
          %{"function_call" => %{"name" => "bad", "arguments" => %{}}},
          %{"function_call" => %{"name" => "bad", "arguments" => "noqweqwe"}}
        ] do
      assert {:error, %Error{type: :output_parser_error, details: %{parser: :openai_functions_parser}}} =
               Runnable.invoke(OutputParser.openai_functions(), bad_input)
    end
  end

  test "OpenAI functions parser validates and casts function args through native schemas" do
    message = %{
      "function_call" => %{
        "name" => "function_name",
        "arguments" => BeamWeaver.JSON.encode!(%{"name" => "value", "age" => 10})
      }
    }

    assert {:ok, %FunctionArgs{name: "value", age: 10}} =
             Runnable.invoke(
               OutputParser.openai_functions(args_only: true, as: FunctionArgs),
               message
             )

    assert {:error, %Error{type: :output_parser_error, details: %{parser: :schema_parser}}} =
             Runnable.invoke(
               OutputParser.openai_functions(args_only: true, as: FunctionArgs),
               %{"function_call" => %{"name" => "function_name", "arguments" => ~s({"age":10})}}
             )
  end

  test "OpenAI functions parser loads unloaded schema modules before validation and cast" do
    module = BeamWeaver.OutputParserTest.UnloadedFunctionArgsFixture
    tmp_dir = Path.join(System.tmp_dir!(), "beam_weaver_output_schema_#{System.unique_integer([:positive])}")
    source_file = Path.join(tmp_dir, "unloaded_function_args_fixture.ex")

    :code.purge(module)
    :code.delete(module)
    File.mkdir_p!(tmp_dir)

    File.write!(source_file, """
    defmodule #{inspect(module)} do
      defstruct [:name, :age]

      def schema do
        %{
          "type" => "object",
          "required" => ["name", "age"],
          "properties" => %{
            "name" => %{"type" => "string"},
            "age" => %{"type" => "integer"}
          }
        }
      end
    end
    """)

    assert {_output, 0} = System.cmd("elixirc", ["-o", tmp_dir, source_file], stderr_to_stdout: true)
    true = Code.prepend_path(String.to_charlist(tmp_dir))

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
      Code.delete_path(String.to_charlist(tmp_dir))
      File.rm_rf(tmp_dir)
    end)

    assert :code.is_loaded(module) == false

    message = %{
      "function_call" => %{
        "name" => "function_name",
        "arguments" => BeamWeaver.JSON.encode!(%{"name" => "Ada", "age" => 37})
      }
    }

    assert {:ok, %{__struct__: ^module, name: "Ada", age: 37}} =
             Runnable.invoke(OutputParser.openai_functions(args_only: true, as: module), message)

    assert {:error, %Error{type: :output_parser_error, details: %{parser: :schema_parser}}} =
             Runnable.invoke(
               OutputParser.openai_functions(args_only: true, as: module),
               %{"function_call" => %{"name" => "function_name", "arguments" => ~s({"age":37})}}
             )
  end

  test "OpenAI functions parser surfaces schema module load failures" do
    module = BeamWeaver.OutputParserTest.UnloadableFunctionArgsFixture
    tmp_dir = Path.join(System.tmp_dir!(), "beam_weaver_bad_output_schema_#{System.unique_integer([:positive])}")
    source_file = Path.join(tmp_dir, "unloadable_function_args_fixture.ex")

    :code.purge(module)
    :code.delete(module)
    File.mkdir_p!(tmp_dir)

    File.write!(source_file, """
    defmodule #{inspect(module)} do
      @on_load :boom

      def boom, do: :erlang.error(:on_load_failed)

      def schema, do: %{"type" => "object"}
    end
    """)

    assert {_output, 0} = System.cmd("elixirc", ["-o", tmp_dir, source_file], stderr_to_stdout: true)
    true = Code.prepend_path(String.to_charlist(tmp_dir))

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
      Code.delete_path(String.to_charlist(tmp_dir))
      File.rm_rf(tmp_dir)
    end)

    message = %{
      "function_call" => %{
        "name" => "function_name",
        "arguments" => BeamWeaver.JSON.encode!(%{"name" => "Ada"})
      }
    }

    capture_log(fn ->
      assert {:error, %Error{type: :runnable_exception, message: error_message}} =
               Runnable.invoke(OutputParser.openai_functions(args_only: true, as: module), message)

      assert error_message =~ ":on_load_failure"
    end)
  end

  test "OpenAI functions parser selects schema casts by function name" do
    cookie = %{
      "function_call" => %{
        "name" => "cookie",
        "arguments" => BeamWeaver.JSON.encode!(%{"name" => "value", "age" => 10})
      }
    }

    dog = %{
      "function_call" => %{
        "name" => "dog",
        "arguments" => BeamWeaver.JSON.encode!(%{"species" => "corgi"})
      }
    }

    parser =
      OutputParser.openai_functions(
        args_only: true,
        as: %{"cookie" => FunctionArgs, "dog" => DogArgs}
      )

    assert {:ok, %FunctionArgs{name: "value", age: 10}} = Runnable.invoke(parser, cookie)
    assert {:ok, %DogArgs{species: "corgi"}} = Runnable.invoke(parser, dog)
  end

  test "schema parser validates required object keys" do
    schema = %{
      "type" => "object",
      "required" => ["answer"],
      "properties" => %{"answer" => %{"type" => "string"}}
    }

    assert {:ok, %{"answer" => "yes"}} =
             Runnable.invoke(OutputParser.schema(schema), ~s({"answer":"yes"}))

    assert {:error,
            %Error{
              type: :output_parser_error,
              details: %{parser: :schema_parser, missing: ["answer"]}
            }} =
             Runnable.invoke(OutputParser.schema(schema), ~s({"other":"no"}))

    assert {:error, %Error{type: :output_parser_error, details: %{parser: :schema_parser}}} =
             Runnable.invoke(OutputParser.schema(schema), ~s(["not", "object"]))
  end

  test "schema parser validates field types and can cast into structs with existing atoms" do
    schema = %{
      "type" => "object",
      "required" => ["answer", "score"],
      "properties" => %{"answer" => %{"type" => "string"}, "score" => %{"type" => "integer"}}
    }

    assert {:ok, %Answer{answer: "yes", score: 7}} =
             Runnable.invoke(
               OutputParser.schema(schema, as: Answer),
               ~s({"answer":"yes","score":7})
             )

    assert {:error,
            %Error{
              type: :output_parser_error,
              details: %{parser: :schema_parser, key: "score", expected: "integer"}
            }} = Runnable.invoke(OutputParser.schema(schema), ~s({"answer":"yes","score":"7"}))
  end

  test "schema parser validates enum constraints and preserves unicode instructions" do
    schema = %{
      "type" => "object",
      "required" => ["action", "action_input", "for_new_lines"],
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["Search", "Create", "Update", "Delete"],
          "description" => "你好, こんにちは, Γειά σου"
        },
        "action_input" => %{"type" => "string"},
        "for_new_lines" => %{"type" => "string"}
      }
    }

    assert OutputParser.get_format_instructions(OutputParser.schema(schema)) =~
             "你好, こんにちは, Γειά σου"

    assert {:ok,
            %{
              "action" => "Update",
              "action_input" => "native schema parser",
              "for_new_lines" => "not_escape_newline:\n escape_newline: \n"
            }} =
             Runnable.invoke(
               OutputParser.schema(schema),
               """
               {
                 "action": "Update",
                 "action_input": "native schema parser",
                 "for_new_lines": "not_escape_newline:\\n escape_newline: \\n"
               }
               """
             )

    assert {:error,
            %Error{
              type: :output_parser_error,
              details: %{parser: :schema_parser, key: "action"}
            }} =
             Runnable.invoke(
               OutputParser.schema(schema),
               ~s({"action":"update","action_input":"bad","for_new_lines":"x"})
             )
  end

  test "parser helpers expose format instructions, streaming transforms, and safe specs" do
    parser = OutputParser.json(partial: true)

    assert OutputParser.get_format_instructions(parser) == "Return a valid JSON value."
    assert {:ok, %{"answer" => 42}} = OutputParser.parse(parser, ~s({"answer":42}))

    assert {:ok, %{"answer" => 42}} =
             OutputParser.parse_partial(OutputParser.json(), ~s({"answer":42} trailing))

    assert {:ok, stream} = OutputParser.transform(parser, [~s({"answer":), "42}"])
    assert Enum.to_list(stream) == [%{}, %{"answer" => 42}]

    assert {:ok, spec} = Runnable.to_spec(OutputParser.openai_tools(first_only: true))
    assert {:ok, restored} = Runnable.from_spec(spec)
    assert {:ok, nil} = Runnable.invoke(restored, [])

    assert {:ok, spec} =
             Runnable.to_spec(
               OutputParser.openai_functions(
                 first_only: false,
                 args_only: true,
                 key_name: "answer",
                 partial: true
               )
             )

    assert {:ok, restored} = Runnable.from_spec(spec)

    assert {:ok, [42]} =
             Runnable.invoke(restored, [
               %{"function" => %{"name" => "answer", "arguments" => ~s({"answer":42)}}
             ])
  end
end
