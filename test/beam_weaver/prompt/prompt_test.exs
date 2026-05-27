defmodule BeamWeaver.PromptTest do
  use ExUnit.Case, async: true

  # Upstream references:
  # - langchain/libs/core/tests/unit_tests/prompts/test_prompt.py
  # - langchain/libs/core/tests/unit_tests/prompts/test_chat.py
  # - langchain/libs/core/tests/unit_tests/test_prompt_values.py

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.Utils
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.ExampleSelector
  alias BeamWeaver.Prompt
  alias BeamWeaver.Runnable

  defmodule UserProfile do
    defstruct [:name]
  end

  defmodule StructuredAnswer do
    defstruct [:answer, :score]
  end

  defmodule StructuredPromptModel do
    @behaviour BeamWeaver.Core.ChatModel

    defstruct [:parent]

    @impl true
    def invoke(%__MODULE__{} = model, messages, opts) do
      if model.parent, do: send(model.parent, {:structured_prompt_model_call, messages, opts})

      tool_name =
        opts
        |> Keyword.get(:tools, [])
        |> List.first()
        |> Tool.name()

      value = Keyword.get(opts, :value, 42)

      {:ok,
       Message.assistant("",
         tool_calls: [
           %{id: "call_structured", name: tool_name, args: %{"name" => "yo", "value" => value}}
         ]
       )}
    end
  end

  def mfa_partial(input), do: String.upcase(input.source)

  test "string templates render safe LangChain-style variables" do
    prompt = Prompt.string("Hello {name}, answer {question}.", partials: %{question: "carefully"})

    assert {:ok, value} = Runnable.invoke(prompt, %{name: "Ada"})
    assert Prompt.to_string(value) == "Hello Ada, answer carefully."
    assert Prompt.to_messages(value) == [Message.user("Hello Ada, answer carefully.")]
  end

  test "string templates accept non-map input through the input variable" do
    assert {:ok, value} = Runnable.invoke(Prompt.string("Summarize: {input}"), "beam")
    assert Prompt.to_string(value) == "Summarize: beam"
  end

  test "template interpolation is safe and does not execute Elixir code" do
    template = "Literal <%= File.read!(\"SECRET\") %> for {name}"

    assert {:ok, value} = Runnable.invoke(Prompt.string(template), %{name: "Ada"})
    assert Prompt.to_string(value) == "Literal <%= File.read!(\"SECRET\") %> for Ada"
  end

  test "template rejects unsafe nested attribute-like paths" do
    for template <- [
          "{name.__class__}",
          "{name.__struct__}",
          "{message.__private__.secret}"
        ] do
      assert {:error, %Error{type: :invalid_prompt_template}} =
               Runnable.invoke(Prompt.string(template), %{"name" => %{"__class__" => "leak"}})
    end
  end

  test "simple template supports nested maps, structs, repeated variables, and falsy values" do
    prompt =
      Prompt.string("{user.name}/{profile.name}/{user.name}/false={enabled}/zero={count}/empty={empty}/nil={nil_value}")

    assert {:ok, value} =
             Runnable.invoke(prompt, %{
               "user" => %{"name" => "Ada"},
               profile: %UserProfile{name: "Grace"},
               enabled: false,
               count: 0,
               empty: "",
               nil_value: nil
             })

    assert Prompt.to_string(value) == "Ada/Grace/Ada/false=false/zero=0/empty=/nil="
  end

  test "safe formatter supports escaped braces, simple numeric specs, and strict variables" do
    prompt = Prompt.string("{{literal}} {name} score={score:.2f}", template_format: :simple)

    assert Prompt.variables(prompt) == ["name", "score"]

    assert {:ok, value} =
             Runnable.invoke(prompt, %{
               name: "Ada",
               score: 3.14159,
               extra: "ignored"
             })

    assert Prompt.to_string(value) == "{literal} Ada score=3.14"

    assert {:error, %Error{type: :invalid_prompt_template, details: %{variable: ""}}} =
             Runnable.invoke(Prompt.string("{}"), %{})

    assert {:error, %Error{type: :prompt_missing_variable, details: %{variable: "missing"}}} =
             Runnable.invoke(Prompt.string("{name} {missing}"), %{name: "Ada"})
  end

  test "safe simple formatter supports constrained format specs and rejects nested specs" do
    cases = [
      {"{value:.2f}", %{value: 3.14159}, ["value"], "3.14"},
      {"{value:>10}", %{value: "cat"}, ["value"], "       cat"},
      {"{value:*^10}", %{value: "cat"}, ["value"], "***cat****"},
      {"{value:,}", %{value: 1_234_567}, ["value"], "1,234,567"},
      {"{value:%}", %{value: 0.125}, ["value"], "12.500000%"},
      {"{value!r}", %{value: "cat"}, ["value"], "'cat'"}
    ]

    for {template, vars, expected_variables, expected_output} <- cases do
      prompt = Prompt.string(template, template_format: :simple)
      assert Prompt.variables(prompt) == expected_variables
      assert {:ok, value} = Runnable.invoke(prompt, vars)
      assert Prompt.to_string(value) == expected_output
    end

    template = "{name:{name.__class__.__name__}}"
    assert {:error, %Error{type: :invalid_prompt_template}} = Prompt.template_variables(template)

    assert {:error, %Error{type: :invalid_prompt_template}} =
             Prompt.check_valid_template(template, ["name"])

    assert {:error, %Error{type: :invalid_prompt_template}} =
             Runnable.invoke(Prompt.string(template), %{name: "hello"})
  end

  test "prompt formatting facade exposes values strings async helpers and template checks" do
    prompt = Prompt.string("Hello {name}")

    assert {:ok, value} = Prompt.format_prompt(prompt, %{name: "Ada"})
    assert %Prompt.Value{text: "Hello Ada"} = value
    assert {:ok, "Hello Ada"} = Prompt.format(prompt, %{name: "Ada"})

    assert {:ok, "Hello Ada"} =
             prompt
             |> Prompt.async_format(%{name: "Ada"})
             |> BeamWeaver.Core.Async.await()

    assert {:ok, %Prompt.Value{text: "Hello Ada"}} =
             prompt
             |> Prompt.async_format_prompt(%{name: "Ada"})
             |> BeamWeaver.Core.Async.await()

    assert Prompt.pretty_repr(prompt) == "Hello {name}"
    assert {:ok, ["name"]} = Prompt.template_variables("Hello {name}", :simple)
    assert :ok = Prompt.check_valid_template("Hello {name}", ["name"])

    assert {:error, %Error{type: :invalid_prompt_template, details: %{missing: ["name"]}}} =
             Prompt.check_valid_template("Hello {name}", [])

    assert {:error, %Error{type: :unsupported_template_format}} =
             Prompt.template_variables("Hello {{ name }}", :jinja2)

    assert Prompt.mustache_schema("{{user.name}} {{#items}}{{label}}{{/items}}") == %{
             "type" => "object",
             "properties" => %{
               "user" => %{"type" => "any"},
               "items" => %{"type" => "any"}
             },
             "required" => ["user", "items"]
           }
  end

  test "unsupported template formats are explicit tagged errors" do
    for format <- [:jinja2, :eex, :unknown] do
      assert {:error, %Error{type: :unsupported_template_format}} =
               Runnable.invoke(Prompt.string("Hello {name}", template_format: format), %{
                 name: "Ada"
               })
    end
  end

  test "mustache templates render safe data variables, sections, and inverted sections" do
    prompt =
      Prompt.string(
        "Hello {{user.name}}.{{#items}} {{label}}={{value}}{{/items}}{{^missing}} none{{/missing}} {{{raw}}}",
        template_format: :mustache
      )

    assert Prompt.variables(prompt) == ["user", "items", "missing", "raw"]

    assert {:ok, value} =
             Runnable.invoke(prompt, %{
               user: %{name: "Ada"},
               items: [%{label: "a", value: 1}, %{label: "b", value: 2}],
               raw: "<ok>"
             })

    assert Prompt.to_string(value) == "Hello Ada. a=1 b=2 none <ok>"
  end

  test "mustache templates reject unsafe attribute paths" do
    prompt = Prompt.string("{{user.__class__.name}}", template_format: :mustache)

    assert {:error, %Error{type: :invalid_prompt_template}} =
             Runnable.invoke(prompt, %{user: %{name: "Ada"}})
  end

  test "template variables do not create atoms from input" do
    variable = "missing_atom_#{System.unique_integer([:positive])}"

    assert {:ok, value} =
             Runnable.invoke(Prompt.string("Value {" <> variable <> "}"), %{variable => "ok"})

    assert Prompt.to_string(value) == "Value ok"

    assert_raise ArgumentError, fn ->
      String.to_existing_atom(variable)
    end
  end

  test "invalid template variable names are rejected" do
    assert {:error, %Error{type: :invalid_prompt_template, details: %{variable: "bad-name"}}} =
             Runnable.invoke(Prompt.string("Hello {bad-name}"), %{})
  end

  test "missing variables return prompt errors" do
    assert {:error, %Error{type: :prompt_missing_variable, details: %{variable: "name"}}} =
             Runnable.invoke(Prompt.string("Hello {name}"), %{})
  end

  test "partials can be values, zero-arity callbacks, one-arity callbacks, and registered MFA" do
    prompt =
      Prompt.string("{static}/{zero}/{one}/{mfa}",
        partials: %{
          static: "value",
          zero: fn -> "zero" end,
          one: fn input -> input.extra end,
          mfa: {__MODULE__, :mfa_partial, []}
        }
      )

    assert {:ok, value} = Runnable.invoke(prompt, %{extra: "one", source: "mfa"})
    assert Prompt.to_string(value) == "value/zero/one/MFA"

    bad = Prompt.string("{bad}", partials: %{bad: fn -> raise "boom" end})

    assert {:error, %Error{type: :prompt_partial_error}} =
             Runnable.invoke(bad, %{})
  end

  test "chat templates render role templates and message placeholders" do
    prompt =
      Prompt.chat([
        Prompt.message(:system, "You are helping {user}."),
        Prompt.placeholder(:history),
        {:user, "{input}"}
      ])

    history = [Message.assistant("Previous answer")]

    assert {:ok, value} =
             Runnable.invoke(prompt, %{user: "Nate", history: history, input: "Continue"})

    assert [
             %Message{role: :system, content: "You are helping Nate."},
             %Message{role: :assistant, content: "Previous answer"},
             %Message{role: :user, content: "Continue"}
           ] = Prompt.to_messages(value)

    assert Prompt.to_string(value) == "You are helping Nate.\nPrevious answer\nContinue"
  end

  test "chat input schemas omit partial variables and optional placeholders" do
    prompt =
      Prompt.chat(
        [
          Prompt.message(:system, "Use {{style}} answers.",
            partials: %{style: "short"},
            template_format: :mustache
          ),
          Prompt.placeholder(:history, optional: true),
          {:user, "{{question}}"}
        ],
        template_format: :mustache,
        partials: %{global: "ignored"}
      )

    assert Prompt.variables(prompt) == ["question"]
    assert Runnable.input_schema(prompt)["required"] == ["question"]

    assert {:ok, value} = Runnable.invoke(prompt, %{question: "Ready?"})

    assert Enum.map(Prompt.to_messages(value), &{&1.role, &1.content}) == [
             {:system, "Use short answers."},
             {:user, "Ready?"}
           ]
  end

  test "chat templates support LangChain role aliases" do
    prompt =
      Prompt.chat([
        {"human", "Question: {input}"},
        {"ai", "Answer: {answer}"}
      ])

    assert {:ok, value} = Runnable.invoke(prompt, %{input: "Q", answer: "A"})

    assert [
             %Message{role: :user, content: "Question: Q"},
             %Message{role: :assistant, content: "Answer: A"}
           ] = Prompt.to_messages(value)
  end

  test "optional placeholders render as empty message lists" do
    prompt =
      Prompt.chat([
        Prompt.message(:system, "Ready"),
        Prompt.placeholder(:history, optional: true),
        Prompt.message(:user, "{input}")
      ])

    assert {:ok, value} = Runnable.invoke(prompt, %{input: "Go"})

    assert [
             %Message{role: :system, content: "Ready"},
             %Message{role: :user, content: "Go"}
           ] = Prompt.to_messages(value)
  end

  test "required placeholders reject missing values and coerce message-like values" do
    prompt = Prompt.chat([Prompt.placeholder(:history)])

    assert {:error, %Error{type: :prompt_missing_variable}} =
             Runnable.invoke(prompt, %{})

    assert {:ok, value} = Runnable.invoke(prompt, %{history: ["message-like"]})
    assert [%Message{role: :user, content: "message-like"}] = Prompt.to_messages(value)

    assert {:error, %Error{type: :invalid_prompt_value}} =
             Runnable.invoke(prompt, %{history: [self()]})
  end

  test "placeholders can keep the most recent messages" do
    prompt = Prompt.chat([Prompt.placeholder(:history, max_length: 2)])

    history = [
      Message.user("first"),
      Message.assistant("second"),
      Message.user("third")
    ]

    assert {:ok, value} = Runnable.invoke(prompt, %{history: history})
    assert ["second", "third"] = Enum.map(Prompt.to_messages(value), & &1.content)
  end

  test "static message parts are preserved in chat templates" do
    prompt =
      Prompt.chat([
        Message.system("Static"),
        Prompt.message(:user, "{input}")
      ])

    assert {:ok, value} = Runnable.invoke(prompt, %{input: "dynamic"})

    assert [
             %Message{role: :system, content: "Static"},
             %Message{role: :user, content: "dynamic"}
           ] = Prompt.to_messages(value)
  end

  test "chat templates support append, extend, concat, and slice helpers" do
    base = Prompt.chat([{"system", "System {topic}"}])

    prompt =
      base
      |> Prompt.append({"human", "{question}"})
      |> Prompt.extend([{"ai", "Draft"}, Prompt.message(:user, "Follow-up")])

    prompt = Prompt.concat(prompt, Prompt.chat([{"assistant", "Done"}]))

    assert {:ok, value} = Runnable.invoke(prompt, %{topic: "math", question: "2+2?"})

    assert Enum.map(Prompt.to_messages(value), &{&1.role, &1.content}) == [
             {:system, "System math"},
             {:user, "2+2?"},
             {:assistant, "Draft"},
             {:user, "Follow-up"},
             {:assistant, "Done"}
           ]

    sliced = Prompt.slice(prompt, 1..2)
    assert {:ok, sliced_value} = Runnable.invoke(sliced, %{question: "Q"})
    assert Enum.map(Prompt.to_messages(sliced_value), & &1.content) == ["Q", "Draft"]
  end

  test "string prompts concatenate when formats match" do
    first = Prompt.string("This is {{thing}}", template_format: :mustache)
    second = Prompt.string(" and {{other}}.", template_format: "mustache")

    prompt = Prompt.concat(first, second)

    assert {:ok, value} = Runnable.invoke(prompt, %{thing: "native", other: "safe"})
    assert Prompt.to_string(value) == "This is native and safe."

    assert {:error, %Error{type: :incompatible_prompt_templates}} =
             Prompt.concat(
               Prompt.string("{one}"),
               Prompt.string("{{two}}", template_format: :mustache)
             )
  end

  test "chat prompts normalize generic chat roles to native user messages" do
    prompt = Prompt.chat([{"critic", "Review {topic}"}])

    assert {:ok, value} = Runnable.invoke(prompt, %{topic: "beam"})

    assert [%Message{role: :user, content: "Review beam", metadata: metadata} = message] =
             Prompt.to_messages(value)

    assert metadata == %{}
    assert {:ok, "Human: Review beam"} = Utils.get_buffer_string([message])

    assert {:ok, ~s(<message type="human">Review beam</message>)} =
             Utils.get_buffer_string([message], format: :xml)
  end

  test "content-block, image, and dict templates preserve structured content" do
    prompt =
      Prompt.chat([
        Prompt.message(:user, [
          %{"type" => "text", "text" => "See {thing}"},
          %{"type" => "unknown", "value" => "{thing}"}
        ]),
        Prompt.image("https://example.com/{file}.png", detail: "high"),
        Prompt.dict(%{"type" => "text", "text" => "Dict {thing}"})
      ])

    assert {:ok, value} = Runnable.invoke(prompt, %{thing: "beam", file: "diagram"})

    assert [
             %Message{
               content: [
                 %{type: :text, text: "See beam"},
                 %ContentBlock.Unknown{value: %{"type" => "unknown", "value" => "beam"}}
               ]
             },
             %Message{
               content: [
                 %ContentBlock.Image{
                   url: "https://example.com/diagram.png",
                   metadata: %{detail: "high"}
                 }
               ]
             },
             %Message{content: [%{type: :text, text: "Dict beam"}]}
           ] = Prompt.to_messages(value)

    assert {:ok, image_value} =
             Runnable.invoke(Prompt.image("https://example.com/{file}.png"), %{file: "diagram"})

    assert Prompt.to_string(image_value) == "https://example.com/diagram.png"
  end

  test "image and dict prompts reject unsafe attribute access and round-trip through safe specs" do
    # Upstream references:
    # - langchain/libs/core/tests/unit_tests/prompts/test_image.py
    # - langchain/libs/core/tests/unit_tests/prompts/test_dict.py
    unsafe_image = Prompt.image("https://example.com/{image.__class__}.png")
    unsafe_dict = Prompt.dict(%{"output" => "{message.__struct__}"})

    assert {:error, %Error{type: :invalid_prompt_template}} =
             Runnable.invoke(unsafe_image, %{"image" => "cat"})

    assert {:error, %Error{type: :invalid_prompt_template}} =
             Runnable.invoke(unsafe_dict, %{"message" => %{}})

    prompt =
      Prompt.chat([
        Prompt.message(:system, "Use image {name}"),
        Prompt.image("data:image/png;base64,{img}", detail: "low"),
        Prompt.dict(%{"type" => "audio", "audio" => "{audio_data}"}),
        Prompt.placeholder(:history, optional: true)
      ])

    assert {:ok, spec} = Runnable.to_spec(prompt)
    assert {:ok, restored} = Runnable.from_spec(spec)

    assert {:ok, value} =
             Runnable.invoke(restored, %{name: "diagram", img: "abc", audio_data: "xyz"})

    assert [
             %Message{role: :system, content: "Use image diagram"},
             %Message{
               role: :user,
               content: [
                 %ContentBlock.Image{
                   url: "data:image/png;base64,abc",
                   metadata: %{detail: "low"}
                 }
               ]
             },
             %Message{role: :user, content: [%{type: :audio, audio: "xyz"}]}
           ] = Prompt.to_messages(value)
  end

  test "few-shot templates render static examples" do
    prompt =
      Prompt.few_shot(
        prefix: "Examples:",
        examples: [%{input: "2+2", output: "4"}, %{input: "3+3", output: "6"}],
        example_prompt: Prompt.string("Q: {input}\nA: {output}"),
        suffix: "Q: {input}\nA:",
        example_separator: "\n---\n"
      )

    assert {:ok, value} = Runnable.invoke(prompt, %{input: "4+4"})

    assert Prompt.to_string(value) == """
           Examples:
           ---
           Q: 2+2
           A: 4
           ---
           Q: 3+3
           A: 6
           ---
           Q: 4+4
           A:\
           """
  end

  test "few-shot templates support suffix-only, partials, and selector-backed examples" do
    suffix_only =
      Prompt.few_shot(
        examples: [],
        example_prompt: Prompt.string("{question}: {answer}"),
        suffix: "This is a {foo} test."
      )

    assert {:ok, value} = Runnable.invoke(suffix_only, %{foo: "bar"})
    assert Prompt.to_string(value) == "This is a bar test."

    selected =
      Prompt.few_shot(
        prefix: "About {content}",
        example_selector:
          ExampleSelector.length_based([
            %{question: "foo", answer: "bar"},
            %{question: "baz", answer: "foo"}
          ]),
        example_prompt: Prompt.string("{question}: {answer}"),
        suffix: "This is a {new_content} test.",
        partials: %{content: fn -> "animals" end}
      )

    assert {:ok, selected_value} = Runnable.invoke(selected, %{new_content: "party"})

    assert Prompt.to_string(selected_value) ==
             "About animals\n\nfoo: bar\n\nbaz: foo\n\nThis is a party test."
  end

  test "few-shot examples are isolated from caller input and reject conflicting sources" do
    leaking =
      Prompt.few_shot(
        examples: [%{question: "foo"}],
        example_prompt: Prompt.string("{question}: {answer}"),
        suffix: "Query: {question}"
      )

    assert {:error, %Error{type: :prompt_missing_variable}} =
             Runnable.invoke(leaking, %{question: "bar", answer: "caller answer"})

    conflicting =
      Prompt.few_shot(
        examples: [%{question: "foo", answer: "bar"}],
        example_selector: ExampleSelector.length_based([%{question: "foo", answer: "bar"}]),
        example_prompt: Prompt.string("{question}: {answer}"),
        suffix: "Query: {question}"
      )

    assert {:error, %Error{type: :invalid_prompt}} =
             Runnable.invoke(conflicting, %{question: "bar"})
  end

  test "few-shot chat templates support selector-backed examples" do
    prompt =
      Prompt.few_shot_chat(
        prefix_messages: [Prompt.message(:system, "You are helpful")],
        example_selector:
          ExampleSelector.length_based([
            %{input: "2+2", output: "4"},
            %{input: "2+3", output: "5"}
          ]),
        example_prompt: Prompt.chat([{"human", "{input}"}, {"ai", "{output}"}]),
        suffix_messages: [Prompt.message(:user, "{input}")]
      )

    assert {:ok, value} = Runnable.invoke(prompt, %{input: "100 + 1"})

    assert Enum.map(Prompt.to_messages(value), &{&1.role, &1.content}) == [
             {:system, "You are helpful"},
             {:user, "2+2"},
             {:assistant, "4"},
             {:user, "2+3"},
             {:assistant, "5"},
             {:user, "100 + 1"}
           ]

    assert Prompt.pretty_repr(prompt) =~ "{input}"

    assert {:ok, async_value} =
             prompt
             |> Prompt.async_format_prompt(%{input: "1 + 1"})
             |> BeamWeaver.Core.Async.await()

    assert Enum.map(Prompt.to_messages(async_value), & &1.role) == [
             :system,
             :user,
             :assistant,
             :user,
             :assistant,
             :user
           ]
  end

  test "structured prompt validates dict and JSON prompt outputs" do
    schema = %{
      "type" => "object",
      "required" => ["answer", "score"],
      "properties" => %{"answer" => %{"type" => "string"}, "score" => %{"type" => "integer"}}
    }

    dict_prompt = Prompt.structured(schema, Prompt.dict(%{"answer" => "{answer}", "score" => 7}))

    assert {:ok, %{"answer" => "yes", "score" => 7}} =
             Runnable.invoke(dict_prompt, %{answer: "yes"})

    assert {:error, %Error{type: :output_parser_error}} =
             Runnable.invoke(Prompt.structured(schema, Prompt.dict(%{"answer" => "yes"})), %{})
  end

  test "structured chat prompts format messages and pipe through native model wrappers" do
    schema = %{
      "title" => "answer",
      "type" => "object",
      "required" => ["name", "value"],
      "properties" => %{
        "name" => %{"type" => "string"},
        "value" => %{"type" => "integer"}
      }
    }

    prompt =
      Prompt.structured_chat(
        [{"human", "hi {{person.name}}"}],
        schema,
        template_format: :mustache,
        value: 7
      )

    assert Prompt.variables(prompt) == ["person"]
    assert Runnable.output_schema(prompt) == schema

    assert {:ok, value} = Runnable.invoke(prompt, %{person: %{name: "Ada"}})
    assert Prompt.to_messages(value) == [Message.user("hi Ada")]

    chain =
      Prompt.pipe_structured(prompt, %StructuredPromptModel{parent: self()}, name: :structured_prompt_chain)

    assert Runnable.get_name(chain) == "structured_prompt_chain"

    assert {:ok, %Message{metadata: %{structured_response: %{"name" => "yo", "value" => 7}}}} =
             Runnable.invoke(chain, %{person: %{name: "Ada"}})

    assert_received {:structured_prompt_model_call, [%Message{role: :user, content: "hi Ada"}], opts}

    assert Keyword.fetch!(opts, :value) == 7
    assert opts |> Keyword.fetch!(:tools) |> Enum.map(&Tool.name/1) == ["answer"]
  end

  test "structured chat prompts round-trip through native specs" do
    schema = %{
      "title" => "answer",
      "type" => "object",
      "required" => ["value"],
      "properties" => %{"value" => %{"type" => "integer"}}
    }

    prompt =
      Prompt.structured_chat(
        [{"human", "score {{person.name}}"}],
        schema,
        template_format: :mustache,
        value: 7
      )

    assert {:ok, spec} = Runnable.to_spec(prompt)
    assert {:ok, restored} = Runnable.from_spec(spec)
    assert {:ok, value} = Runnable.invoke(restored, %{person: %{name: "Ada"}})
    assert Prompt.to_messages(value) == [Message.user("score Ada")]
    assert restored.structured_output_opts == [value: 7]
  end

  test "structured chat prompts report invalid mustache templates as tagged prompt errors" do
    prompt =
      Prompt.structured_chat(
        [{"human", "hi {{}}"}],
        %{"type" => "object", "properties" => %{}, "title" => "answer"},
        template_format: :mustache
      )

    assert {:error, %Error{type: :invalid_prompt_template}} =
             Runnable.invoke(prompt, %{})
  end

  test "format_document injects content and metadata" do
    document = %BeamWeaver.Core.Document{content: "Beam", metadata: %{"source" => "docs"}}

    assert {:ok, "docs: Beam"} =
             Prompt.format_document(document, Prompt.string("{source}: {page_content}"))

    assert {:ok, "docs: Beam"} =
             document
             |> Prompt.async_format_document(Prompt.string("{source}: {page_content}"))
             |> BeamWeaver.Core.Async.await()
  end

  test "prompts implement runnable batch, stream, transform, introspection, and safe specs" do
    prompt = Prompt.string("Hello {name}")

    assert {:ok, values} = Runnable.batch(prompt, [%{name: "Ada"}, %{name: "Grace"}])
    assert Enum.map(values, &Prompt.to_string/1) == ["Hello Ada", "Hello Grace"]

    assert {:ok, stream} = Runnable.stream(prompt, %{name: "Ada"})
    assert [value] = Enum.to_list(stream)
    assert Prompt.to_string(value) == "Hello Ada"

    assert {:ok, transform} = Runnable.transform(prompt, [%{name: "Ada"}, %{name: "Grace"}])
    assert Enum.map(transform, &Prompt.to_string/1) == ["Hello Ada", "Hello Grace"]

    assert Runnable.input_schema(prompt)["required"] == ["name"]
    assert Runnable.output_schema(prompt) == %{"type" => "string"}

    assert {:ok, spec} = Runnable.to_spec(prompt)
    assert {:ok, restored} = Runnable.from_spec(spec)
    assert {:ok, restored_value} = Runnable.invoke(restored, %{name: "Ada"})
    assert Prompt.to_string(restored_value) == "Hello Ada"

    assert {:error, %Error{type: :unsupported_runnable_spec}} =
             Prompt.string("Hello {name}", partials: %{name: fn -> "Ada" end})
             |> Runnable.to_spec()
  end

  test "prompts load and save native JSON/YAML specs" do
    dir = tmp_dir!("prompt-load-save")
    json_path = Path.join(dir, "prompt.json")
    yaml_path = Path.join(dir, "prompt.yaml")

    prompt =
      Prompt.chat([
        Prompt.message(:system, "Use {style} answers."),
        Prompt.placeholder(:history, optional: true),
        Prompt.message(:user, "{input}")
      ])
      |> Prompt.partial(%{style: "short"})

    assert :ok = Prompt.save(prompt, json_path)
    assert :ok = Prompt.save(prompt, yaml_path)

    for path <- [json_path, yaml_path] do
      assert {:ok, loaded} = Prompt.load(path)
      assert {:ok, value} = Runnable.invoke(loaded, %{input: "Hi"})

      assert Enum.map(Prompt.to_messages(value), &{&1.role, &1.content}) == [
               {:system, "Use short answers."},
               {:user, "Hi"}
             ]
    end
  end

  test "few-shot prompts round-trip through declarative specs" do
    dir = tmp_dir!("prompt-few-shot-save")
    path = Path.join(dir, "few_shot.yaml")

    prompt =
      Prompt.few_shot(
        prefix: "Write antonyms.",
        examples: [%{"input" => "happy", "output" => "sad"}],
        example_prompt: Prompt.string("Input: {input}\nOutput: {output}"),
        suffix: "Input: {adjective}\nOutput:"
      )

    assert :ok = Prompt.save(prompt, path)
    assert {:ok, loaded} = Prompt.load(path)
    assert {:ok, value} = Runnable.invoke(loaded, %{adjective: "tall"})

    assert Prompt.to_string(value) ==
             "Write antonyms.\n\nInput: happy\nOutput: sad\n\nInput: tall\nOutput:"
  end

  test "loader rejects legacy prompt config shapes" do
    dir = tmp_dir!("legacy-prompt-load")
    config_path = Path.join(dir, "prompt.json")

    File.write!(
      config_path,
      BeamWeaver.JSON.encode!(%{"_type" => "prompt", "template" => "Hello {name}"})
    )

    assert {:error, %Error{type: :invalid_prompt_spec}} = Prompt.load(config_path)
  end

  test "prompt save resolves symlinks before extension checks" do
    dir = tmp_dir!("prompt-save-symlink")
    target = Path.join(dir, "malicious.py")
    symlink = Path.join(dir, "output.json")
    File.ln_s!(target, symlink)

    assert {:error, %Error{type: :unsupported_prompt_format}} =
             Prompt.save(Prompt.string("Hello {name}"), symlink)

    refute File.exists?(target)
  end

  test "plain template files become string prompts" do
    dir = tmp_dir!("prompt-from-file")
    path = Path.join(dir, "template.txt")
    File.write!(path, "This is a {foo} test with special character €.")

    assert {:ok, prompt} = Prompt.from_file(path, partials: %{foo: "native"})
    assert {:ok, value} = Runnable.invoke(prompt, %{})
    assert Prompt.to_string(value) == "This is a native test with special character €."
  end

  test "plain template files support explicit text encodings" do
    dir = tmp_dir!("prompt-from-file-encoding")
    path = Path.join(dir, "template.txt")

    File.write!(path, ["This is a {foo} test with special character ", <<0x80>>, "."])

    assert {:ok, prompt} = Prompt.from_file(path, encoding: :cp1252)
    assert {:ok, value} = Runnable.invoke(prompt, %{foo: "native"})
    assert Prompt.to_string(value) == "This is a native test with special character €."

    assert {:error, %Error{type: :prompt_encoding_error}} = Prompt.from_file(path)
  end

  defp tmp_dir!(name) do
    dir = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
