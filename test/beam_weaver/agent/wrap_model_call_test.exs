defmodule BeamWeaver.Agent.WrapModelCallTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent
  alias BeamWeaver.Agent.ExtendedModelResponse
  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Agent.ModelResponse
  alias BeamWeaver.Agent.ProviderProfile
  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Overwrite
  alias BeamWeaver.Models
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events

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
    use BeamWeaver.Agent.Middleware

    def name(_middleware), do: :logging

    def wrap_model_call(_middleware, request, handler) do
      send(request.runtime.context.parent, :outer_before)
      response = handler.(request)
      send(request.runtime.context.parent, :outer_after)
      response
    end
  end

  defmodule InnerLoggingMiddleware do
    use BeamWeaver.Agent.Middleware

    def name(_middleware), do: :inner_logging

    def wrap_model_call(_middleware, request, handler) do
      send(request.runtime.context.parent, :inner_before)
      response = handler.(request)
      send(request.runtime.context.parent, :inner_after)
      response
    end
  end

  defmodule UppercaseMiddleware do
    use BeamWeaver.Agent.Middleware

    def name(_middleware), do: :uppercase

    def wrap_model_call(_middleware, request, handler) do
      with {:ok, %ModelResponse{messages: [%Message{} = message]}} <- handler.(request) do
        Message.assistant(String.upcase(message.content))
      end
    end
  end

  defmodule SystemPromptMiddleware do
    use BeamWeaver.Agent.Middleware

    def name(_middleware), do: :system_prompt

    def wrap_model_call(_middleware, request, handler) do
      request
      |> ModelRequest.override(system_message: Message.system("native system prompt"))
      |> handler.()
    end
  end

  defmodule ModelOverrideMiddleware do
    use BeamWeaver.Agent.Middleware

    def name(_middleware), do: :model_override

    def wrap_model_call(_middleware, request, handler) do
      request
      |> ModelRequest.override(model: request.runtime.context.model)
      |> handler.()
    end
  end

  defmodule RecoverNetworkMiddleware do
    use BeamWeaver.Agent.Middleware

    def name(_middleware), do: :recover_network

    def wrap_model_call(_middleware, request, handler) do
      case handler.(request) do
        {:error, %Error{type: :network_error}} ->
          Message.assistant("Network issue, try again later")

        other ->
          other
      end
    end
  end

  defmodule InnerCommandMiddleware do
    use BeamWeaver.Agent.Middleware

    def name(_middleware), do: :inner_command

    def wrap_model_call(_middleware, request, handler) do
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
    use BeamWeaver.Agent.Middleware

    def name(_middleware), do: :outer_command

    def wrap_model_call(_middleware, request, handler) do
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
    use BeamWeaver.Agent.Middleware

    def name(_middleware), do: :retry_outer

    def wrap_model_call(_middleware, request, handler) do
      _discarded = handler.(request)
      handler.(request)
    end
  end

  defmodule StructuredConflictMiddleware do
    use BeamWeaver.Agent.Middleware

    def name(_middleware), do: :structured_conflict

    def wrap_model_call(_middleware, request, handler) do
      with {:ok, %ModelResponse{} = response} <- handler.(request) do
        %ExtendedModelResponse{
          model_response: %{response | structured_response: %{from: "model"}},
          command: %Command{update: %{structured_response: %{from: "command"}}}
        }
      end
    end
  end

  defmodule MessageOverwriteMiddleware do
    use BeamWeaver.Agent.Middleware

    def name(_middleware), do: :message_overwrite

    def wrap_model_call(_middleware, request, handler) do
      with {:ok, %ModelResponse{} = response} <- handler.(request) do
        %ExtendedModelResponse{
          model_response: response,
          command: %Command{
            update: %{
              messages: Overwrite.new([Message.user("Compacted input", id: "compacted")])
            }
          }
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

  defmodule ModelOverrideAgent do
    use BeamWeaver.Agent

    model(%RecordingModel{reply: "from the agent's model"})
    middleware([ModelOverrideMiddleware])
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

  defmodule MessageOverwriteAgent do
    use BeamWeaver.Agent

    model(%RecordingModel{reply: "model"})
    middleware([MessageOverwriteMiddleware])
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

  test "a model string that middleware puts on the request is created for the call" do
    model = scripted_fake_model("from the override")

    assert {:ok, %{messages: [_user, %Message{content: "from the override"}]}} =
             Agent.invoke(ModelOverrideAgent, %{messages: [Message.user("hi")]}, context: %{model: model})
  end

  test "a streamed call goes to the model string that middleware puts on the request" do
    model = scripted_fake_model("streamed from the override")

    assert {:ok, events} =
             ModelOverrideAgent.stream_events(%{messages: [Message.user("hi")]},
               context: %{model: model},
               model_opts: [stream: true]
             )

    events = Enum.to_list(events)
    tokens = for %Envelope{event: %Events.Token{text: text}} <- events, do: text

    assert Enum.join(tokens) == "streamed from the override"
    refute Enum.any?(events, &match?(%Envelope{event: %Events.Error{}}, &1))
  end

  test "an invalid model that middleware puts on the request fails with :invalid_agent_model" do
    for model <- [fn -> :model end, %{api_key: "sk-secret"}] do
      assert {:error, %Error{type: :invalid_agent_model} = error} =
               Agent.invoke(ModelOverrideAgent, %{messages: [Message.user("hi")]}, context: %{model: model})

      assert %{model_request: %{messages: [%{role: :user, content: "hi"}]}} = error.details
      refute inspect(error) =~ "sk-secret"
    end
  end

  test "a model string from middleware that can't be resolved returns its error with the request" do
    assert {:error, %Error{type: :unsupported_provider} = error} =
             Agent.invoke(ModelOverrideAgent, %{messages: [Message.user("hi")]}, context: %{model: "nope:model"})

    assert error.details.model_request.model == "nope:model"
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

  test "message overwrite commands preserve the model response message" do
    assert {:ok, %{messages: messages}} =
             Agent.invoke(MessageOverwriteAgent, %{messages: [Message.user("hi")]})

    assert Enum.map(messages, &{&1.role, &1.content}) == [
             {:user, "Compacted input"},
             {:assistant, "model"}
           ]
  end

  # A "fake:..." model string of its own, whose provider profile scripts the
  # reply, so the reply shows which model answered. It takes the model profile
  # of "fake:chat", which streams.
  defp scripted_fake_model(reply) do
    model = "fake:override-#{System.unique_integer([:positive])}"
    %{profile: profile} = Models.init_chat_model!("fake:chat")
    init_kwargs = [responses: [reply], profile: profile]
    :ok = ProviderProfile.register_provider_profile(model, ProviderProfile.new(init_kwargs: init_kwargs))
    model
  end
end
