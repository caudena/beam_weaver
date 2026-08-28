defmodule BeamWeaver.SkillTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Skill

  describe "parse/2" do
    test "parses the complete supported metadata subset" do
      document = """
      ---
      name: source-review
      description: Review supplied sources before answering.
      license: MIT
      compatibility: Requires public web access.
      metadata:
        owner: docs
        maturity: stable
      allowed-tools: read_file, web_search web_fetch
      argument-hint: <topic or URL>
      disable-model-invocation: true
      user-invocable: false
      context: fork
      ---
      # Source review

      Research $ARGUMENTS.
      """

      assert {:ok,
              %Skill{
                schema_version: 1,
                name: "source-review",
                description: "Review supplied sources before answering.",
                license: "MIT",
                compatibility: "Requires public web access.",
                metadata: %{"owner" => "docs", "maturity" => "stable"},
                allowed_tools: ["read_file", "web_search", "web_fetch"],
                argument_hint: "<topic or URL>",
                disable_model_invocation: true,
                user_invocable: false,
                context: :fork,
                body: "# Source review\n\nResearch $ARGUMENTS.\n"
              }} = Skill.parse(document, expected_name: "source-review")
    end

    test "applies safe defaults and accepts CRLF documents" do
      document =
        "---\r\nname: concise\r\ndescription: Keep the answer concise.\r\n---\r\nBody\r\n"

      assert {:ok,
              %Skill{
                name: "concise",
                metadata: %{},
                allowed_tools: [],
                argument_hint: nil,
                disable_model_invocation: false,
                user_invocable: true,
                context: :inline,
                body: "Body\r\n"
              }} = Skill.parse(document)
    end

    test "requires strict frontmatter and matching lowercase kebab-case names" do
      assert_invalid("name: no-frontmatter", "start with YAML frontmatter")

      assert_invalid(
        "---\nname: Bad_Name\ndescription: Invalid name\n---\nBody",
        "name is invalid"
      )

      assert_invalid(
        "---\nname: alpha\ndescription: A\n---\nBody",
        "match its containing directory",
        expected_name: "beta"
      )

      assert_invalid(
        "---\nname: alpha\nname: beta\ndescription: A\n---\nBody",
        "duplicate fields"
      )
    end

    test "rejects authority-bearing, dynamic, and unknown fields" do
      rejected_fields = [
        "agent: analyst",
        "model: gpt-5",
        "effort: high",
        "background: true",
        "hooks: {}",
        "shell: echo unsafe",
        "dynamic: $SHELL",
        "arbitrary-field: value"
      ]

      for field <- rejected_fields do
        assert_invalid(
          "---\nname: safe\ndescription: Safe skill\n#{field}\n---\nBody",
          "unsupported fields"
        )
      end
    end

    test "rejects unsafe field shapes and parser options without raising" do
      assert_invalid(
        "---\nname: safe\ndescription: Safe skill\nmetadata:\n  owner: first\n  owner: second\n---\nBody",
        "duplicate fields"
      )

      assert_invalid(
        "---\nname: safe\ndescription: Safe skill\nmetadata:\n  count: 1\n---\nBody",
        "bounded string map"
      )

      assert_invalid(
        "---\nname: safe\ndescription: Safe skill\nmetadata:\n  1: value\n---\nBody",
        "bounded string map"
      )

      assert_invalid(
        "---\nname: safe\ndescription: Safe skill\nallowed-tools:\n  - read_file\n---\nBody",
        "must be a string"
      )

      assert_invalid(
        "---\nname: safe\ndescription: Safe skill\ncontext: detached\n---\nBody",
        "inline or fork"
      )

      assert {:error, %Error{type: :invalid_skill, message: message}} =
               Skill.parse("---\nname: safe\ndescription: Safe\n---\nBody", [:invalid])

      assert message =~ "keyword list"

      assert {:error, %Error{type: :invalid_skill, message: message}} =
               Skill.parse(
                 "---\nname: safe\ndescription: Safe\n---\nBody",
                 expected_name: "safe",
                 expected_name: "safe"
               )

      assert message =~ "duplicated"
    end

    test "rejects YAML aliases, tags, merge keys, and quoted top-level keys" do
      assert_invalid(
        "---\nname: safe\ndescription: &description Safe skill\n---\nBody",
        "unsupported YAML features"
      )

      assert_invalid(
        "---\nname: safe\ndescription: !custom Safe skill\n---\nBody",
        "unsupported YAML features"
      )

      assert_invalid(
        "---\nname: safe\ndescription: Safe skill\nmetadata:\n  <<: *defaults\n---\nBody",
        "unsupported YAML features"
      )

      assert_invalid(
        "---\n\"name\": safe\ndescription: Safe skill\n---\nBody",
        "unsupported YAML syntax"
      )
    end

    test "turns malformed YAML into a typed error" do
      assert_invalid(
        "---\nname: [\ndescription: Broken\n---\nBody",
        "invalid YAML"
      )
    end
  end

  describe "render/2" do
    test "replaces only the literal arguments placeholder" do
      skill = %Skill{
        name: "literal",
        description: "Literal rendering",
        body: "Use $ARGUMENTS. Keep $ARGUMENTS[0], $ARGUMENTSX, ${ARGUMENTS}, $0, and $CLAUDE_SESSION_ID."
      }

      assert {:ok, rendered} = Skill.render(skill, ~S|topic "quoted" && $(not-run)|)

      assert rendered ==
               ~S|Use topic "quoted" && $(not-run). Keep $ARGUMENTS[0], $ARGUMENTSX, ${ARGUMENTS}, $0, and $CLAUDE_SESSION_ID.|
    end

    test "appends nonempty arguments when the literal placeholder is absent" do
      skill = %Skill{name: "plain", description: "Plain", body: "Follow these steps.\n"}

      assert {:ok, "Follow these steps.\n\nARGUMENTS:\nfirst second"} =
               Skill.render(skill, "first second")

      assert {:ok, "Follow these steps.\n"} = Skill.render(skill, "")

      assert {:ok, "ARGUMENTS:\nfirst"} =
               Skill.render(%{skill | body: ""}, "first")
    end

    test "rejects invalid and oversized rendering inputs" do
      skill = %Skill{name: "safe", description: "Safe", body: "$ARGUMENTS"}

      assert {:error, %Error{type: :invalid_skill, message: message}} =
               Skill.render(skill, <<0>>)

      assert message =~ "must not contain NUL"

      assert {:error, %Error{type: :invalid_skill}} =
               Skill.render(skill, :binary.copy("a", 65_537))

      expanding = %Skill{
        name: "safe",
        description: "Safe",
        body: Enum.map_join(1..17, " ", fn _ -> "$ARGUMENTS" end)
      }

      assert {:error, %Error{type: :invalid_skill, message: message}} =
               Skill.render(expanding, :binary.copy("a", 65_536))

      assert message =~ "exceed the supported size"
    end
  end

  defp assert_invalid(document, expected_message, opts \\ []) do
    assert {:error, %Error{type: :invalid_skill, message: message}} =
             Skill.parse(document, opts)

    assert message =~ expected_message
  end
end
