defmodule BeamWeaver.DocSnippetsTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.TestSupport.DocSnippets

  defp run(markdown), do: DocSnippets.run_markdown!(markdown, "docs/harness_fixture.md")

  defp modes(markdown),
    do: for(block <- DocSnippets.parse_markdown(markdown, "docs/harness_fixture.md"), do: {block.mode, block.arg})

  test "run blocks carry bindings and aliases, and `#=>` matches the last value" do
    assert :ok =
             run("""
             ```elixir
             alias BeamWeaver.Core.Message
             greeting = "hello"
             ```

             Text between blocks.

             ```elixir
             Message.user(greeting)
             #=> %Message{role: :user, content: "hello"}
             ```
             """)
  end

  test "a failing `#=>` reports the block's file and line" do
    error =
      assert_raise ExUnit.AssertionError, fn ->
        run("""
        Intro.

        ```elixir
        1 + 1
        #=> 3
        ```
        """)
      end

    assert error.message =~ "docs/harness_fixture.md:4 (run snippet) result does not match `#=> 3`"
  end

  test "MyApp modules live in a page namespace that is purged afterwards" do
    assert :ok =
             run("""
             ```elixir
             defmodule MyApp.Greeter do
               def hello(name), do: "Hello, \#{name}!"
             end
             ```

             ```elixir
             MyApp.Greeter.hello("Ada")
             #=> "Hello, Ada!"
             ```
             """)

    refute Code.loaded?(DocSnippets.HarnessFixture.Greeter)
  end

  test "compile blocks are checked without running and see earlier compile blocks" do
    assert :ok =
             run("""
             ```elixir
             defmodule MyApp.Live do
               def call, do: System.fetch_env!("BEAM_WEAVER_DOCS_NEVER_SET")
             end
             ```

             <!-- snippet: compile -->
             ```elixir
             MyApp.Live.call()
             ```
             """)

    assert :ok =
             run("""
             <!-- snippet: compile -->
             ```elixir
             raise "compile blocks never run"
             ```
             """)
  end

  test "compile blocks fail on undefined modules and functions" do
    error =
      assert_raise ExUnit.AssertionError, fn ->
        run("""
        <!-- snippet: compile -->
        ```elixir
        BeamWeaver.Core.Message.nope(1)
        ```
        """)
      end

    assert error.message =~ "docs/harness_fixture.md:3 (compile snippet)"
    assert error.message =~ "BeamWeaver.Core.Message.nope/1 is undefined or private"
  end

  test "modes are detected from content" do
    markdown = """
    ```elixir
    import Config
    config :beam_weaver, :openai, api_key: "sk-test"
    ```

    ```elixir
    def deps do
      [{:beam_weaver, "~> 0.1"}]
    end
    ```

    ```elixir
    model "fake:chat", responses: ["Hi"]
    system_prompt "Be brief."
    ```

    ```elixir
    @impl true
    def checkpointer, do: nil
    ```

    ```elixir
    {:ok, model} = BeamWeaver.Models.init_chat_model("openai:gpt-5.4")
    ```

    ```elixir
    1 + 1
    ```

    <!-- snippet: skip shows output only -->
    ```elixir
    not code
    ```
    """

    assert modes(markdown) == [
             {"config", ""},
             {"mix", ""},
             {"fragment", "agent"},
             {"fragment", ""},
             {"compile", ""},
             {"run", ""},
             {"skip", "shows output only"}
           ]
  end

  test "fragments compile inside a module, with DSL lines inside an agent" do
    assert :ok =
             run("""
             ```elixir
             model "fake:chat", responses: ["Hi"]
             system_prompt "Be brief."
             ```

             ```elixir
             def twice(value), do: value * 2
             ```
             """)
  end

  test "a marker applies only to the block right after it" do
    assert [{"run", ""}] =
             modes("""
             <!-- snippet: compile -->

             ```elixir
             1 + 1
             ```
             """)
  end

  test "an unknown marker fails its page, not the parse" do
    markdown = "<!-- snippet: compiled -->\n```elixir\n:ok\n```\n"
    assert [{"invalid", "unknown snippet mode \"compiled\""}] = modes(markdown)

    error = assert_raise ExUnit.AssertionError, fn -> run(markdown) end
    assert error.message =~ "docs/harness_fixture.md:3 (invalid snippet) unknown snippet mode"
  end

  test "skips need a reason and stay under the page cap" do
    assert_raise RuntimeError, ~r/snippet skip needs a reason/, fn ->
      run("""
      <!-- snippet: skip -->
      ```elixir
      :ok
      ```
      """)
    end

    assert_raise RuntimeError, ~r/2 skipped blocks exceed the cap of 1/, fn ->
      run("""
      <!-- snippet: skip one -->
      ```elixir
      :ok
      ```

      <!-- snippet: skip two -->
      ```elixir
      :ok
      ```
      """)
    end
  end

  test "syntax errors report the block" do
    error = assert_raise ExUnit.AssertionError, fn -> run("```elixir\nfoo(\n```\n") end
    assert error.message =~ "docs/harness_fixture.md:2 (run snippet) syntax error"
  end

  # docs_test.exs checks these pages while it loads: ExUnit refuses test
  # modules defined once every test file has loaded.
  test "pages that define ExUnit test modules are found, and check_page/1 returns failures" do
    assert DocSnippets.defines_test_modules?("docs/testing.md")
    refute DocSnippets.defines_test_modules?("README.md")

    assert {:error, message} = DocSnippets.check_page("docs/harness_fixture.md")
    assert message =~ "docs/harness_fixture.md"
  end

  test "agents run on the fake model inside run blocks" do
    assert :ok =
             run("""
             ```elixir
             defmodule MyApp.LookupOrder do
               use BeamWeaver.Tool

               name "lookup_order"
               description "Look up an order by id."

               schema do
                 field :order_id, :string, required: true
               end

               @impl true
               def invoke(_tool, %{"order_id" => id}, _opts), do: {:ok, "\#{id} shipped on Monday"}
             end

             defmodule MyApp.SupportAgent do
               use BeamWeaver.Agent

               model "fake:chat",
                 responses: [
                   BeamWeaver.Models.FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1001"}),
                   "Order A-1001 shipped on Monday."
                 ]

               tools [MyApp.LookupOrder]
             end
             ```

             ```elixir
             {:ok, %{messages: messages}} =
               MyApp.SupportAgent.invoke(%{messages: [BeamWeaver.Core.Message.user("Where is A-1001?")]})

             List.last(messages).content
             #=> "Order A-1001 shipped on Monday."
             ```
             """)
  end
end
