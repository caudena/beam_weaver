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

    assert [%Message{role: :tool, metadata: %{error_type: :structured_output_validation_error}}] =
             response.messages

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

  defp model(table, tool_calls) do
    %SequentialStructuredModel{table: table, parent: self(), tool_calls: tool_calls}
  end

  defp weather_call(id, args) do
    [%{id: id, name: "WeatherReport", args: args}]
  end

  defp feedback_message?(%Message{role: :user, content: content}) when is_binary(content) do
    content =~ "Error:" and content =~ "Please try again"
  end

  defp feedback_message?(_message), do: false

  defp feedback_content(%Message{role: :user, content: content}) when is_binary(content) do
    if feedback_message?(%Message{role: :user, content: content}), do: content
  end

  defp feedback_content(_message), do: nil
end
