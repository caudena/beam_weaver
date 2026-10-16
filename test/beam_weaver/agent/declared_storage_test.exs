defmodule BeamWeaver.Agent.DeclaredStorageTest.Storage do
  # Storage an agent module declares through functions: the long-lived
  # savers, stores and caches a test's setup creates, and a function that
  # wrongly creates a new saver on every call.
  def checkpointer, do: :persistent_term.get({__MODULE__, :checkpointer})
  def store, do: :persistent_term.get({__MODULE__, :store})
  def cache, do: :persistent_term.get({__MODULE__, :cache})

  def new_checkpointer, do: BeamWeaver.Checkpoint.ETS.new()
end

defmodule BeamWeaver.Agent.DeclaredStorageTest.VisitCounter do
  # Counts the calls on a thread in the run's store, and reports what it saw
  # with the run's cache.
  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Memory

  @impl true
  def before_agent(_middleware, _state, runtime) do
    visits =
      case Memory.get(runtime.store, ["visits"], "count") do
        {:ok, item} -> item.value["count"]
        :error -> 0
      end

    {:ok, _item} = Memory.put(runtime.store, ["visits"], "count", %{"count" => visits + 1})
    send(:persistent_term.get(BeamWeaver.Agent.DeclaredStorageTest), {:visits, visits, runtime.cache})
    nil
  end
end

defmodule BeamWeaver.Agent.DeclaredStorageTest.SupportAgent do
  use BeamWeaver.Agent

  model "fake:chat", responses: ["Hi Ada!", "You're Ada."]
end

defmodule BeamWeaver.Agent.DeclaredStorageTest.StoredAgent do
  # Declares functions that return storage created once.
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.DeclaredStorageTest.Storage

  model "fake:chat", responses: ["Hi Ada!", "You're Ada."]
  middleware [BeamWeaver.Agent.DeclaredStorageTest.VisitCounter]
  checkpointer Storage.checkpointer()
  store Storage.store()
  cache Storage.cache()
end

defmodule BeamWeaver.Agent.DeclaredStorageTest.DefinedStorageAgent do
  # Defines checkpointer/0 instead of declaring it.
  use BeamWeaver.Agent

  model "fake:chat", responses: ["Hi Ada!", "You're Ada."]

  @impl true
  def checkpointer, do: BeamWeaver.Agent.DeclaredStorageTest.Storage.checkpointer()
end

defmodule BeamWeaver.Agent.DeclaredStorageTest.ForgetfulAgent do
  # Declares a function that returns a new saver on every call.
  use BeamWeaver.Agent

  model "fake:chat", responses: ["Hi Ada!", "You're Ada."]
  checkpointer BeamWeaver.Agent.DeclaredStorageTest.Storage.new_checkpointer()
end

defmodule BeamWeaver.Agent.DeclaredStorageTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias BeamWeaver.Agent.DeclaredStorageTest.DefinedStorageAgent
  alias BeamWeaver.Agent.DeclaredStorageTest.ForgetfulAgent
  alias BeamWeaver.Agent.DeclaredStorageTest.Storage
  alias BeamWeaver.Agent.DeclaredStorageTest.StoredAgent
  alias BeamWeaver.Agent.DeclaredStorageTest.SupportAgent
  alias BeamWeaver.Cache
  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Memory

  @thread %{"configurable" => %{"thread_id" => "ticket-42"}}

  defp compile_error(source) do
    error = assert_raise CompileError, fn -> Code.compile_string(source, "declared_storage_probe.ex") end
    Exception.message(error)
  end

  defp texts(state), do: Enum.map(state.messages, &Message.text/1)

  defp put_storage(storage) do
    for {name, value} <- storage, do: :persistent_term.put({Storage, name}, value)
    on_exit(fn -> for {name, _value} <- storage, do: :persistent_term.erase({Storage, name}) end)
  end

  describe "an in-memory saver, store or cache created in a declaration" do
    test "doesn't compile, and the error says what to do instead" do
      message =
        compile_error("""
        defmodule BeamWeaver.Agent.DeclaredStorageTest.InlineSaver do
          use BeamWeaver.Agent
          model "fake:chat", responses: ["one", "two"]
          checkpointer BeamWeaver.Checkpoint.ETS.new()
        end
        """)

      assert message =~
               "declared_storage_probe.ex:4: the `checkpointer` declaration creates a new, empty in-memory saver"

      assert message =~
               "with `BeamWeaver.Checkpoint.ETS.new()` each time BeamWeaver.Agent.DeclaredStorageTest.InlineSaver runs"

      assert message =~ "get_state/1 finds nothing"
      assert message =~ "a test's setup, and pass it to each call with `checkpointer: saver`"
      assert message =~ "`checkpointer MyApp.Storage.checkpointer()`"
      assert message =~ "or use BeamWeaver.Checkpoint.Ecto"
    end

    test "is found through aliases, in stores and caches, and inside other declarations" do
      assert compile_error("""
             defmodule BeamWeaver.Agent.DeclaredStorageTest.InlineStore do
               use BeamWeaver.Agent
               alias BeamWeaver.Memory.ETS
               model "fake:chat"
               store ETS.new()
             end
             """) =~ "the `store` declaration creates a new, empty in-memory store with `ETS.new()`"

      assert compile_error("""
             defmodule BeamWeaver.Agent.DeclaredStorageTest.InlineCache do
               use BeamWeaver.Agent
               alias BeamWeaver.Cache
               model "fake:chat"
               cache Cache.ETS.new(max_entries: 100)
             end
             """) =~ "pass it to each call with `cache: cache`"

      assert compile_error("""
             defmodule BeamWeaver.Agent.DeclaredStorageTest.InlineFiles do
               use BeamWeaver.Agent
               model "fake:chat"
               filesystem BeamWeaver.Filesystem.Store.new(store: BeamWeaver.Memory.ETS.new())
             end
             """) =~ "declared_storage_probe.ex:4: the `filesystem` declaration creates a new, empty in-memory store"
    end

    test "doesn't compile in a graph module either" do
      assert compile_error("""
             defmodule BeamWeaver.Agent.DeclaredStorageTest.InlineGraphSaver do
               use BeamWeaver.Agent
               alias BeamWeaver.Checkpoint
               checkpointer Checkpoint.ETS.new()

               def graph, do: BeamWeaver.Graph.new()
             end
             """) =~ "the `checkpointer` declaration creates a new, empty in-memory saver with `Checkpoint.ETS.new()`"
    end

    test "inside a function compiles: it runs when the function is called" do
      assert [{BeamWeaver.Agent.DeclaredStorageTest.ScratchStore, _beam}] =
               Code.compile_string("""
               defmodule BeamWeaver.Agent.DeclaredStorageTest.ScratchStore do
                 use BeamWeaver.Agent
                 model "fake:chat"

                 tools [
                   BeamWeaver.Core.Tool.from_function!(
                     name: "scratch",
                     description: "Counts in a scratch store.",
                     input_schema: %{"type" => "object"},
                     handler: fn _input, _opts -> inspect(BeamWeaver.Memory.ETS.new()) end
                   )
                 ]
               end
               """)
    end
  end

  describe "storage that outlives the call" do
    test "a saver created once and passed to each call keeps the thread" do
      opts = [checkpointer: Checkpoint.ETS.new(), config: @thread]

      assert {:ok, _first} = SupportAgent.invoke(%{messages: ["I'm Ada."]}, opts)
      assert {:ok, second} = SupportAgent.invoke(%{messages: ["Who am I?"]}, opts)

      assert texts(second) == ["I'm Ada.", "Hi Ada!", "Who am I?", "You're Ada."]
      assert {:ok, %{values: %{messages: [_, _, _, _]}}} = SupportAgent.get_state(opts)
    end

    test "declared functions that return storage created once keep the thread, the store and the cache" do
      cache = Cache.ETS.new()
      put_storage(checkpointer: Checkpoint.ETS.new(), store: Memory.ETS.new(), cache: cache)
      :persistent_term.put(__MODULE__, self())
      on_exit(fn -> :persistent_term.erase(__MODULE__) end)

      log =
        capture_log(fn ->
          assert {:ok, _first} = StoredAgent.invoke(%{messages: ["I'm Ada."]}, config: @thread)
          assert {:ok, second} = StoredAgent.invoke(%{messages: ["Who am I?"]}, config: @thread)
          assert texts(second) == ["I'm Ada.", "Hi Ada!", "Who am I?", "You're Ada."]
        end)

      refute log =~ "declaration returned a new"
      assert_received {:visits, 0, ^cache}
      assert_received {:visits, 1, ^cache}
      assert {:ok, %{values: %{messages: [_, _, _, _]}}} = StoredAgent.get_state(config: @thread)
    end

    test "a declared function that returns a new ETS saver on every call logs a warning once" do
      first_log =
        capture_log(fn ->
          assert {:ok, _first} = ForgetfulAgent.invoke(%{messages: ["I'm Ada."]}, config: @thread)
        end)

      assert first_log =~
               "BeamWeaver.Agent.DeclaredStorageTest.ForgetfulAgent's `checkpointer` declaration returned a new " <>
                 "BeamWeaver.Checkpoint.ETS saver when it was evaluated again"

      assert first_log =~ "pass it per call with `checkpointer:`"

      second_log =
        capture_log(fn ->
          assert {:ok, second} = ForgetfulAgent.invoke(%{messages: ["Who am I?"]}, config: @thread)
          # The new saver held nothing: the thread started over.
          assert texts(second) == ["Who am I?", "Hi Ada!"]
        end)

      refute second_log =~ "ForgetfulAgent's `checkpointer` declaration"
    end
  end

  describe "checkpointer/0 and store/0" do
    test "return what the declarations evaluate to" do
      # A definition from `__before_compile__` didn't replace the default, so
      # both returned nil.
      saver = Checkpoint.ETS.new()
      store = Memory.ETS.new()
      put_storage(checkpointer: saver, store: store, cache: Cache.ETS.new())

      assert StoredAgent.checkpointer() == saver
      assert StoredAgent.store() == store
      assert SupportAgent.checkpointer() == nil
      assert SupportAgent.store() == nil
    end

    test "a module may define them instead of declaring them" do
      saver = Checkpoint.ETS.new()
      put_storage(checkpointer: saver)

      assert {:ok, _first} = DefinedStorageAgent.invoke(%{messages: ["I'm Ada."]}, config: @thread)
      assert {:ok, second} = DefinedStorageAgent.invoke(%{messages: ["Who am I?"]}, config: @thread)

      assert texts(second) == ["I'm Ada.", "Hi Ada!", "Who am I?", "You're Ada."]
      assert DefinedStorageAgent.checkpointer() == saver
    end

    test "declaring and defining the same one doesn't compile" do
      assert compile_error("""
             defmodule BeamWeaver.Agent.DeclaredStorageTest.DoubleStore do
               use BeamWeaver.Agent
               model "fake:chat"
               store BeamWeaver.Agent.DeclaredStorageTest.Storage.store()

               def store, do: nil
             end
             """) =~
               "BeamWeaver.Agent.DeclaredStorageTest.DoubleStore declares `store` and defines store/0; keep one of them"
    end
  end
end
