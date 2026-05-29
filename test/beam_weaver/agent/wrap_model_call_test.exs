defmodule BeamWeaver.Agent.WrapModelCallTest do
  use ExUnit.Case, async: true

  # Upstream behavioral evidence:
  # - langchain/libs/langchain_v1/tests/unit_tests/agents/middleware/core/test_wrap_model_call.py
  # - langchain/libs/langchain_v1/tests/unit_tests/agents/middleware/core/test_wrap_model_call_state_update.py

  alias BeamWeaver.Agent
  alias BeamWeaver.Agent.ExtendedModelResponse
  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Agent.ModelResponse
  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph.Command

  defmodule RecordingModel do
    @behaviour ChatModel

    defstruct [:parent, :reply, :table]

    @impl true
    def invoke(%__MODULE__{table: table} = model, messages, opts) do
      if parent = parent(model.parent, opts), do: send(parent, {:model_call, messages, opts})
      table = table(table, opts)

      reply =
        if table do
          count = :ets.update_counter(table, :calls, 1, {:calls, 0})
          "#{model.reply || "reply"} #{count}"
        else
          model.reply || "reply"
        end

      {:ok, Message.assistant(reply)}
    end

    defp parent(:context, opts), do: opts |> Keyword.get(:context, %{}) |> Map.get(:parent)
    defp parent(parent, _opts), do: parent

    defp table(:context, opts), do: opts |> Keyword.get(:context, %{}) |> Map.get(:table)
    defp table(table, _opts), do: table
  end

  defmodule FailingModel do
    @behaviour ChatModel

    defstruct []

    @impl true
    def invoke(%__MODULE__{}, _messages, _opts),
      do: {:error, Error.new(:network_error, "network down")}
  end

  defmodule ProviderError do
    defexception [:type, :message, details: %{}]
  end

  defmodule ProviderFailingModel do
    @behaviour ChatModel

    defstruct []

    @impl true
    def invoke(%__MODULE__{}, _messages, _opts) do
      {:error,
       %ProviderError{
         type: :http_error,
         message: "provider authentication failed",
         details: %{status: 401, pid: self()}
       }}
    end
  end

  defmodule LoggingMiddleware do
    @behaviour BeamWeaver.Agent.Middleware

    def name(_middleware), do: :logging

    def wrap_model_call(request, handler) do
      send(request.runtime.context.parent, :outer_before)
      response = handler.(request)
      send(request.runtime.context.parent, :outer_after)
      response
    end
  end

  defmodule InnerLoggingMiddleware do
    @behaviour BeamWeaver.Agent.Middleware

    def name(_middleware), do: :inner_logging

    def wrap_model_call(request, handler) do
      send(request.runtime.context.parent, :inner_before)
      response = handler.(request)
      send(request.runtime.context.parent, :inner_after)
      response
    end
  end

  defmodule UppercaseMiddleware do
    @behaviour BeamWeaver.Agent.Middleware

    def name(_middleware), do: :uppercase

    def wrap_model_call(request, handler) do
      with {:ok, %ModelResponse{messages: [%Message{} = message]}} <- handler.(request) do
        Message.assistant(String.upcase(message.content))
      end
    end
  end

  defmodule SystemPromptMiddleware do
    @behaviour BeamWeaver.Agent.Middleware

    def name(_middleware), do: :system_prompt

    def wrap_model_call(request, handler) do
      request
      |> ModelRequest.override(system_message: Message.system("native system prompt"))
      |> handler.()
    end
  end

  defmodule RecoverNetworkMiddleware do
    @behaviour BeamWeaver.Agent.Middleware

    def name(_middleware), do: :recover_network

    def wrap_model_call(request, handler) do
      case handler.(request) do
        {:error, %Error{type: :network_error}} ->
          Message.assistant("Network issue, try again later")

        other ->
          other
      end
    end
  end

  defmodule InnerCommandMiddleware do
    @behaviour BeamWeaver.Agent.Middleware

    def name(_middleware), do: :inner_command

    def wrap_model_call(request, handler) do
      with {:ok, %ModelResponse{} = response} <- handler.(request) do
        [message | _] = response.messages

        %ExtendedModelResponse{
          model_response: response,
          command: %Command{
            update: %{
              messages: [Message.user("Inner msg", id: "inner")],
              inner_key: message.content
            }
          }
        }
      end
    end
  end

  defmodule OuterCommandMiddleware do
    @behaviour BeamWeaver.Agent.Middleware

    def name(_middleware), do: :outer_command

    def wrap_model_call(request, handler) do
      with {:ok, %ModelResponse{} = response} <- handler.(request) do
        %ExtendedModelResponse{
          model_response: response,
          command: %Command{
            update: %{
              messages: [Message.user("Outer msg", id: "outer")],
              outer_key: "from_outer"
            }
          }
        }
      end
    end
  end

  defmodule RetryOuterMiddleware do
    @behaviour BeamWeaver.Agent.Middleware

    def name(_middleware), do: :retry_outer

    def wrap_model_call(request, handler) do
      _discarded = handler.(request)
      handler.(request)
    end
  end

  defmodule StructuredConflictMiddleware do
    @behaviour BeamWeaver.Agent.Middleware

    def name(_middleware), do: :structured_conflict

    def wrap_model_call(request, handler) do
      with {:ok, %ModelResponse{} = response} <- handler.(request) do
        %ExtendedModelResponse{
          model_response: %{response | structured_response: %{from: "model"}},
          command: %Command{update: %{structured_response: %{from: "command"}}}
        }
      end
    end
  end

  defmodule OrderAgent do
    use BeamWeaver.Agent

    model(%RecordingModel{parent: :context, reply: "ok"})
    middleware([LoggingMiddleware, InnerLoggingMiddleware])
  end

  defmodule RewriteAgent do
    use BeamWeaver.Agent

    model(%RecordingModel{reply: "hello"})
    middleware([UppercaseMiddleware])
  end

  defmodule PromptAgent do
    use BeamWeaver.Agent

    model(%RecordingModel{parent: :context, reply: "ok"})
    middleware([SystemPromptMiddleware])
  end

  defmodule ErrorRecoveryAgent do
    use BeamWeaver.Agent

    model(%FailingModel{})
    middleware([RecoverNetworkMiddleware])
  end

  defmodule ProviderErrorAgent do
    use BeamWeaver.Agent

    model(%ProviderFailingModel{})
  end

  defmodule WrappedProviderErrorAgent do
    use BeamWeaver.Agent

    model(%ProviderFailingModel{})
    middleware([SystemPromptMiddleware])
  end

  defmodule CommandAgent do
    use BeamWeaver.Agent

    model(%RecordingModel{reply: "model"})
    middleware([OuterCommandMiddleware, InnerCommandMiddleware])
  end

  defmodule RetryCommandAgent do
    use BeamWeaver.Agent

    model(%RecordingModel{table: :context, reply: "attempt"})
    middleware([RetryOuterMiddleware, InnerCommandMiddleware])
  end

  defmodule StructuredConflictAgent do
    use BeamWeaver.Agent

    model(%RecordingModel{reply: "model"})
    middleware([StructuredConflictMiddleware])
  end

  test "model wrappers compose outside-in around the immutable request" do
    parent = self()

    assert {:ok, %{messages: [_user, %Message{content: "ok"}]}} =
             Agent.invoke(OrderAgent, %{messages: [Message.user("hi")]}, context: %{parent: parent})

    assert_receive :outer_before
    assert_receive :inner_before
    assert_receive {:model_call, _messages, _opts}
    assert_receive :inner_after
    assert_receive :outer_after
  end

  test "wrapper middleware can rewrite model responses and short-circuit errors" do
    assert {:ok, %{messages: [_user, %Message{content: "HELLO"}]}} =
             Agent.invoke(RewriteAgent, %{messages: [Message.user("hi")]})

    assert {:ok, %{messages: [_user, %Message{content: "Network issue, try again later"}]}} =
             Agent.invoke(ErrorRecoveryAgent, %{messages: [Message.user("hi")]})
  end

  test "provider-specific model errors survive wrapped and unwrapped model calls" do
    for agent <- [ProviderErrorAgent, WrappedProviderErrorAgent] do
      assert {:error, %Error{type: :http_error, message: "provider authentication failed"} = error} =
               Agent.invoke(agent, %{messages: [Message.user("hi")]})

      assert error.details.status == 401
      assert error.details.pid =~ "#PID"
      assert error.details.reason =~ "ProviderError"
    end
  end

  test "request overrides preserve value semantics and affect the downstream model call" do
    parent = self()

    assert {:ok, %{messages: [_user, %Message{content: "ok"}]}} =
             Agent.invoke(PromptAgent, %{messages: [Message.user("hi")]}, context: %{parent: parent})

    assert_receive {:model_call, [%Message{role: :system, content: "native system prompt"} | _], _opts}
  end

  test "extended responses propagate inner and outer graph updates through composition" do
    assert {:ok, state} = Agent.invoke(CommandAgent, %{messages: [Message.user("hi")]})

    assert Enum.map(state.messages, & &1.content) == [
             "hi",
             "model",
             "Inner msg",
             "Outer msg"
           ]

    assert state.inner_key == "model"
    assert state.outer_key == "from_outer"
  end

  test "retrying a wrapped handler keeps only the returned attempt's command updates" do
    table = :ets.new(:retry_command_agent, [:set, :public])

    assert {:ok, state} =
             Agent.invoke(RetryCommandAgent, %{messages: [Message.user("hi")]}, context: %{table: table})

    assert Enum.map(state.messages, & &1.content) == ["hi", "attempt 2", "Inner msg"]
    assert state.inner_key == "attempt 2"
  end

  test "separate model and command state updates preserve last-value conflicts" do
    assert {:error, %Error{type: :invalid_update}} =
             Agent.invoke(StructuredConflictAgent, %{messages: [Message.user("hi")]})
  end
end
