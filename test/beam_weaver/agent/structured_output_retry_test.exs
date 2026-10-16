defmodule BeamWeaver.Agent.StructuredOutputRetryTest do
  use ExUnit.Case, async: true

  # Upstream reference:

  alias BeamWeaver.Agent
  alias BeamWeaver.Agent.Middleware.StructuredOutputRetry
  alias BeamWeaver.Agent.StructuredOutput
  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message

  defmodule SequentialStructuredModel do
    @behaviour ChatModel

    defstruct [:table, :parent, tool_calls: []]

    @impl true
    def invoke(%__MODULE__{} = model, messages, opts) do
      call = :ets.update_counter(model.table, :calls, 1, {:calls, 0})
      if model.parent, do: send(model.parent, {:structured_retry_call, call, messages, opts})

      tool_calls =
        Enum.at(model.tool_calls, call - 1) || List.last(model.tool_calls) || []

      {:ok, Message.assistant("", tool_calls: tool_calls)}
    end
  end

  defmodule ContextModel do
    @behaviour ChatModel

    defstruct []

    @impl true
    def invoke(%__MODULE__{}, messages, opts) do
      opts
      |> Keyword.fetch!(:context)
      |> Map.fetch!(:model)
      |> ChatModel.invoke(messages, opts)
    end
  end

  defmodule RetryAgent do
    use BeamWeaver.Agent

    @weather_schema %{
      "title" => "WeatherReport",
      "type" => "object",
      "required" => ["temperature", "conditions"],
      "properties" => %{
        "temperature" => %{"type" => "number"},
        "conditions" => %{"type" => "string"}
      }
    }

    model(%ContextModel{})
    middleware([{StructuredOutputRetry, max_retries: 2}])
    response_format(StructuredOutput.tool(@weather_schema, handle_errors: false))
  end

  defmodule OneRetryAgent do
    use BeamWeaver.Agent

    @weather_schema %{
      "title" => "WeatherReport",
      "type" => "object",
      "required" => ["temperature", "conditions"],
      "properties" => %{
        "temperature" => %{"type" => "number"},
        "conditions" => %{"type" => "string"}
      }
    }

    model(%ContextModel{})
    middleware([{StructuredOutputRetry, max_retries: 1}])
    response_format(StructuredOutput.tool(@weather_schema, handle_errors: false))
  end

  defmodule ZeroRetryAgent do
    use BeamWeaver.Agent

    @weather_schema %{
      "title" => "WeatherReport",
      "type" => "object",
      "required" => ["temperature", "conditions"],
      "properties" => %{
        "temperature" => %{"type" => "number"},
        "conditions" => %{"type" => "string"}
      }
    }

    model(%ContextModel{})
    middleware([{StructuredOutputRetry, max_retries: 0}])
    response_format(StructuredOutput.tool(@weather_schema, handle_errors: false))
  end

  test "retries invalid structured output until a valid tool response arrives" do
    table = :ets.new(:structured_retry_success, [:set, :public])

    model =
      model(table, [
        weather_call("1", %{"temperature" => "not-a-float", "conditions" => "sunny"}),
        weather_call("2", %{"temperature" => 72.5}),
        weather_call("3", %{"temperature" => 72.5, "conditions" => "sunny"})
      ])

    assert {:ok, state} =
             Agent.invoke(RetryAgent, %{messages: [Message.user("weather in Tokyo")]}, context: %{model: model})

    assert state.structured_response == %{"temperature" => 72.5, "conditions" => "sunny"}
    assert :ets.lookup(table, :calls) == [{:calls, 3}]
    assert Enum.any?(state.messages, &feedback_message?/1)
  end

  test "returns the structured output error after retries are exhausted" do
    table = :ets.new(:structured_retry_exhausted, [:set, :public])

    model =
      model(table, [
        weather_call("1", %{"temperature" => "invalid", "conditions" => "sunny"}),
        weather_call("2", %{"temperature" => "also-invalid", "conditions" => "cloudy"}),
        weather_call("3", %{"temperature" => "still-invalid", "conditions" => "rainy"})
      ])

    assert {:error, %Error{type: :structured_output_validation_error}} =
             Agent.invoke(RetryAgent, %{messages: [Message.user("weather in Tokyo")]}, context: %{model: model})

    assert :ets.lookup(table, :calls) == [{:calls, 3}]
  end

  test "does not retry when the first structured output is valid" do
    table = :ets.new(:structured_retry_first_success, [:set, :public])

    model =
      model(table, [
        weather_call("1", %{"temperature" => 68.0, "conditions" => "cloudy"})
      ])

    assert {:ok, state} =
             Agent.invoke(RetryAgent, %{messages: [Message.user("weather in Paris")]}, context: %{model: model})

    assert state.structured_response == %{"temperature" => 68.0, "conditions" => "cloudy"}
    assert :ets.lookup(table, :calls) == [{:calls, 1}]
    refute Enum.any?(state.messages, &feedback_message?/1)
  end

  test "zero retries fails immediately" do
    table = :ets.new(:structured_retry_zero, [:set, :public])

    model =
      model(table, [
        weather_call("1", %{"temperature" => "invalid", "conditions" => "sunny"}),
        weather_call("2", %{"temperature" => 72.5, "conditions" => "sunny"})
      ])

    assert {:error, %Error{type: :structured_output_validation_error}} =
             Agent.invoke(ZeroRetryAgent, %{messages: [Message.user("weather in Berlin")]}, context: %{model: model})

    assert :ets.lookup(table, :calls) == [{:calls, 1}]
  end

  test "retry feedback is included in the next model request and final state" do
    table = :ets.new(:structured_retry_feedback, [:set, :public])

    model =
      model(table, [
        weather_call("1", %{"temperature" => 75.0}),
        weather_call("2", %{"temperature" => 75.0, "conditions" => "rainy"})
      ])

    assert {:ok, state} =
             Agent.invoke(OneRetryAgent, %{messages: [Message.user("weather in Seattle")]}, context: %{model: model})

    assert state.structured_response == %{"temperature" => 75.0, "conditions" => "rainy"}
    assert Enum.any?(state.messages, &feedback_message?/1)

    assert_received {:structured_retry_call, 1, first_messages, _opts}
    assert_received {:structured_retry_call, 2, second_messages, _opts}
    refute Enum.any?(first_messages, &feedback_message?/1)
    assert Enum.any?(second_messages, &feedback_message?/1)

    feedback = Enum.find_value(second_messages, &feedback_content/1)
    assert feedback =~ "Details:"
    assert feedback =~ "missing"
    assert feedback =~ "conditions"
  end

  test "the retry request holds the failed answer, answered with the error" do
    table = :ets.new(:structured_retry_failed_answer, [:set, :public])

    model =
      model(table, [
        weather_call("1", %{"temperature" => 75.0}),
        weather_call("2", %{"temperature" => 75.0, "conditions" => "rainy"})
      ])

    assert {:ok, state} =
             Agent.invoke(OneRetryAgent, %{messages: [Message.user("weather in Seattle")]}, context: %{model: model})

    assert_received {:structured_retry_call, 2, second_messages, _opts}

    assert [
             %Message{role: :user},
             %Message{role: :assistant, tool_calls: [%{id: "1"}]},
             %Message{role: :tool, tool_call_id: "1", metadata: %{error_type: :structured_output_validation_error}}
           ] = second_messages

    assert [:user, :assistant, :tool, :assistant, :tool] = Enum.map(state.messages, & &1.role)
  end

  defmodule Triage do
    use BeamWeaver.Schema

    field :category, :string
    field :priority, :string
  end

  defmodule ScriptedRetryAgent do
    use BeamWeaver.Agent

    alias BeamWeaver.Models.FakeChatModel

    model "fake:chat",
      responses: [
        FakeChatModel.final(%{category: "shipping"}),
        FakeChatModel.final(%{category: "shipping", priority: "high"})
      ]

    middleware [StructuredOutputRetry]
    response_schema Triage
  end

  test "a scripted model answers the retry with its next turn" do
    assert {:ok, result} = ScriptedRetryAgent.invoke(%{messages: ["My order A-1001 never arrived!"]})
    assert result.structured_response == %{"category" => "shipping", "priority" => "high"}
    assert [:user, :assistant, :user, :assistant] = Enum.map(result.messages, & &1.role)
  end

  test "the error returned after the last retry has no raw reply" do
    table = :ets.new(:structured_retry_error_details, [:set, :public])
    model = model(table, [weather_call("1", %{"temperature" => "invalid", "conditions" => "sunny"})])

    assert {:error, %Error{details: details}} =
             Agent.invoke(OneRetryAgent, %{messages: [Message.user("weather in Oslo")]}, context: %{model: model})

    refute Map.has_key?(details, :failed_reply)
    assert %{model_response: %{role: :assistant}} = details
  end

  test "validates retry options" do
    assert_raise ArgumentError, ~r/max_retries/, fn ->
      StructuredOutputRetry.new(max_retries: -1)
    end
  end

  test "tool strategy error handling can be scoped by structured error type" do
    schema = %{
      "title" => "WeatherReport",
      "type" => "object",
      "required" => ["temperature", "conditions"],
      "properties" => %{
        "temperature" => %{"type" => "number"},
        "conditions" => %{"type" => "string"}
      }
    }

    invalid_message =
      Message.assistant("",
        tool_calls: [
          %{id: "call-invalid", name: "WeatherReport", args: %{"temperature" => "hot"}}
        ]
      )

    assert {:ok, response} =
             StructuredOutput.handle_model_output(
               invalid_message,
               StructuredOutput.tool(schema, handle_errors: [:structured_output_validation_error])
             )

    assert [
             ^invalid_message,
             %Message{
               role: :tool,
               tool_call_id: "call-invalid",
               metadata: %{error_type: :structured_output_validation_error}
             }
           ] = response.messages

    assert {:error, %Error{type: :structured_output_validation_error}} =
             StructuredOutput.handle_model_output(
               invalid_message,
               StructuredOutput.tool(schema, handle_errors: [:multiple_structured_outputs])
             )
  end

  test "multiple structured output errors include structured tool names" do
    schema = %{
      "oneOf" => [
        %{"title" => "weather_schema", "type" => "object", "required" => ["temperature"]},
        %{"title" => "location_schema", "type" => "object", "required" => ["city"]}
      ]
    }

    message =
      Message.assistant("",
        tool_calls: [
          %{id: "call-weather", name: "weather_schema", args: %{"temperature" => 72}},
          %{id: "call-location", name: "location_schema", args: %{"city" => "Paris"}}
        ]
      )

    assert {:error, %Error{type: :multiple_structured_outputs, message: error_message}} =
             StructuredOutput.handle_model_output(
               message,
               StructuredOutput.tool(schema, handle_errors: false)
             )

    assert error_message =~ "weather_schema"
    assert error_message =~ "location_schema"
  end

  defmodule Echo do
    use BeamWeaver.Tool

    name "echo"
    description "Echo a value."

    schema do
      field :value, :string
    end

    @impl true
    def invoke(_tool, %{"value" => value}, _opts), do: {:ok, value}
  end

  defmodule SecondTryAgent do
    use BeamWeaver.Agent

    alias BeamWeaver.Models.FakeChatModel

    model "fake:chat",
      responses: [
        FakeChatModel.final(%{category: "shipping"}),
        FakeChatModel.final(%{category: "shipping", priority: "high"})
      ]

    response_schema BeamWeaver.Agent.StructuredOutputRetryTest.Triage, strategy: :tool
  end

  defmodule NeverValidAgent do
    use BeamWeaver.Agent

    alias BeamWeaver.Models.FakeChatModel

    model "fake:chat", responses: [FakeChatModel.final(%{})], parent: self()
    response_schema BeamWeaver.Agent.StructuredOutputRetryTest.Triage, strategy: :tool, max_retries: 1
  end

  defmodule NoErrorHandlingAgent do
    use BeamWeaver.Agent

    alias BeamWeaver.Models.FakeChatModel

    model "fake:chat", responses: [FakeChatModel.final(%{})], parent: self()
    response_schema BeamWeaver.Agent.StructuredOutputRetryTest.Triage, strategy: :tool, handle_errors: false
  end

  defmodule ToolsThenSecondTryAgent do
    use BeamWeaver.Agent

    alias BeamWeaver.Models.FakeChatModel

    model "fake:chat",
      responses: [
        FakeChatModel.tool_call("echo", %{"value" => "A-1001 is lost"}),
        "Order A-1001 is lost.",
        FakeChatModel.final(%{priority: "high"}),
        FakeChatModel.final(%{category: "shipping", priority: "high"})
      ]

    tools [BeamWeaver.Agent.StructuredOutputRetryTest.Echo]
    response_schema BeamWeaver.Agent.StructuredOutputRetryTest.Triage, strategy: :tool
  end

  defmodule TextFirstAgent do
    use BeamWeaver.Agent

    alias BeamWeaver.Models.FakeChatModel

    model "fake:chat",
      responses: ["It's about shipping, and urgent.", FakeChatModel.final(%{category: "shipping", priority: "high"})]

    response_schema BeamWeaver.Agent.StructuredOutputRetryTest.Triage, strategy: :tool
  end

  defmodule TextOnlyAgent do
    use BeamWeaver.Agent

    model "fake:chat", responses: ["It's about shipping, and urgent."], parent: self()
    response_schema BeamWeaver.Agent.StructuredOutputRetryTest.Triage, strategy: :tool, max_retries: 1
  end

  defmodule ToolsThenTextOnlyAgent do
    use BeamWeaver.Agent

    alias BeamWeaver.Models.FakeChatModel

    model "fake:chat",
      responses: [FakeChatModel.tool_call("echo", %{"value" => "A-1001 is lost"}), "Order A-1001 is lost."],
      parent: self()

    tools [BeamWeaver.Agent.StructuredOutputRetryTest.Echo]
    response_schema BeamWeaver.Agent.StructuredOutputRetryTest.Triage, strategy: :tool, max_retries: 1
  end

  defmodule RetriedTextAgent do
    use BeamWeaver.Agent

    alias BeamWeaver.Models.FakeChatModel

    model "fake:chat",
      responses: ["It's about shipping, and urgent.", FakeChatModel.final(%{category: "shipping", priority: "high"})]

    middleware [BeamWeaver.Agent.Middleware.StructuredOutputRetry]
    response_schema BeamWeaver.Agent.StructuredOutputRetryTest.Triage, strategy: :tool, handle_errors: false
  end

  test "StructuredOutputRetry retries an answer that calls no tool" do
    assert {:ok, result} = RetriedTextAgent.invoke(%{messages: ["My order never arrived!"]})

    assert result.structured_response == %{"category" => "shipping", "priority" => "high"}
    assert Enum.map(result.messages, & &1.role) == [:user, :assistant, :user, :assistant, :tool]
  end

  test "a tool-strategy answer that calls no tool goes back to the model with the error" do
    assert {:ok, result} = TextFirstAgent.invoke(%{messages: ["My order never arrived!"]})

    assert result.structured_response == %{"category" => "shipping", "priority" => "high"}
    assert Enum.map(result.messages, & &1.role) == [:user, :assistant, :user, :assistant, :tool]

    error = Enum.at(result.messages, 2)
    assert Message.text(error) =~ "Structured output error: the answer must be a call to the triage tool"
  end

  test "answers that call no tool count against max_retries" do
    assert {:error, %Error{type: :missing_structured_output, details: %{attempts: 2}}} =
             TextOnlyAgent.invoke(%{messages: ["My order never arrived!"]})

    assert_received {:fake_chat_model_call, _messages, _opts}
    assert_received {:fake_chat_model_call, _messages, _opts}
    refute_received {:fake_chat_model_call, _messages, _opts}
  end

  test "the structured-response call after a tool loop stops after max_retries answers that call no tool" do
    assert {:error, %Error{type: :missing_structured_output, details: %{attempts: 2}}} =
             ToolsThenTextOnlyAgent.invoke(%{messages: ["My order never arrived!"]}, recursion_limit: 50)

    # The tool round, then two answers in the structured-response call.
    for _call <- 1..4, do: assert_received({:fake_chat_model_call, _messages, _opts})
    refute_received {:fake_chat_model_call, _messages, _opts}
  end

  test "an invalid tool-strategy answer goes back to the model, which answers again" do
    assert {:ok, result} = SecondTryAgent.invoke(%{messages: ["My order never arrived!"]})

    assert result.structured_response == %{"category" => "shipping", "priority" => "high"}
    assert Enum.map(result.messages, & &1.role) == [:user, :assistant, :tool, :assistant, :tool]

    [_user, %Message{tool_calls: [call]}, error | _rest] = result.messages
    assert error.tool_call_id == call.id
    assert Message.text(error) =~ "Structured output error"
    assert Message.text(error) =~ "priority"
  end

  test "the structured-response call after a tool loop retries an invalid answer too" do
    assert {:ok, result} = ToolsThenSecondTryAgent.invoke(%{messages: ["My order never arrived!"]})

    assert result.structured_response == %{"category" => "shipping", "priority" => "high"}

    assert Enum.map(result.messages, & &1.role) ==
             [:user, :assistant, :tool, :assistant, :assistant, :tool, :assistant, :tool]
  end

  test "the run fails once the answers fail max_retries times in a row" do
    assert {:error, %Error{type: :structured_output_validation_error, details: %{attempts: 2, missing: missing}}} =
             NeverValidAgent.invoke(%{messages: ["My order never arrived!"]})

    assert Enum.sort(missing) == ["category", "priority"]
    assert_received {:fake_chat_model_call, _messages, _opts}
    assert_received {:fake_chat_model_call, _messages, _opts}
    refute_received {:fake_chat_model_call, _messages, _opts}
  end

  test "with handle_errors: false the first invalid answer fails the run" do
    assert {:error, %Error{type: :structured_output_validation_error}} =
             NoErrorHandlingAgent.invoke(%{messages: ["My order never arrived!"]})

    assert_received {:fake_chat_model_call, _messages, _opts}
    refute_received {:fake_chat_model_call, _messages, _opts}
  end

  defp model(table, tool_calls) do
    %SequentialStructuredModel{table: table, parent: self(), tool_calls: tool_calls}
  end

  defp weather_call(id, args) do
    [%{id: id, name: "WeatherReport", args: args}]
  end

  defp feedback_message?(%Message{role: role, content: content}) when role in [:user, :tool] and is_binary(content) do
    content =~ "Error:" and content =~ "Please try again"
  end

  defp feedback_message?(_message), do: false

  defp feedback_content(%Message{content: content} = message) do
    if feedback_message?(message), do: content
  end
end
