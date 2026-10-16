defmodule BeamWeaver.Provider.WarningTelemetryTest do
  # Telemetry handlers are global, so no other test may emit these events
  # while these run.
  use ExUnit.Case, async: false

  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Models

  # A call's `metadata` can carry a user id, so the warnings a call emits
  # name the parameters or features only, never the call's values.
  @user_id "user-4f1d9a"

  setup do
    handler = "warning-telemetry-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [[:beam_weaver, :models, :param_warning], [:beam_weaver, :provider, :unsupported_feature]],
      &__MODULE__.forward/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  def forward(event, measurements, metadata, parent), do: send(parent, {:telemetry, event, measurements, metadata})

  describe "a param warning" do
    # Each call sends parameters the model's profile doesn't list, which
    # `param_policy: :warn` lets through with a warning. xAI, Moonshot,
    # DeepSeek and Z.ai take no request metadata.
    for {name, model, init_opts, call_opts, warned} <- [
          {"Anthropic", "anthropic:claude-haiku-4-5", [], [frequency_penalty: 0.5, metadata: %{user_id: @user_id}],
           [:frequency_penalty]},
          {"OpenAI Responses", "openai:gpt-4.1", [api: :responses], [stop: ["END"], metadata: %{"user" => @user_id}],
           [:stop]},
          {"OpenAI Chat Completions", "openai:gpt-4.1", [api: :chat_completions],
           [truncation: :auto, metadata: %{"user" => @user_id}], [:truncation]},
          {"xAI Responses", "xai:grok-4.6", [api: :responses], [metadata: %{"user" => @user_id}], [:metadata]},
          {"xAI Chat Completions", "xai:grok-4.6", [api: :chat_completions], [metadata: %{"user" => @user_id}],
           [:metadata]},
          {"Moonshot", "moonshot:kimi-k2.6", [], [seed: 7, metadata: %{"user" => @user_id}], [:metadata, :seed]},
          {"DeepSeek", "deepseek:deepseek-flash", [], [seed: 7, metadata: %{"user" => @user_id}], [:metadata, :seed]},
          {"Z.ai", "zai:glm-5.2", [], [seed: 7, metadata: %{"user" => @user_id}], [:metadata, :seed]}
        ] do
      test "from #{name} names the parameters, not the call's metadata" do
        model = Models.init_chat_model!(unquote(model), [api_key: "k"] ++ unquote(init_opts))
        id = model.model

        call_opts = [param_policy: :warn] ++ unquote(Macro.escape(call_opts))

        assert {:ok, _body} = model.__struct__.request_body(model, [Message.user("hi")], call_opts)

        assert_receive {:telemetry, [:beam_weaver, :models, :param_warning], %{count: count}, %{model: ^id} = metadata}
        assert count == length(unquote(warned))
        assert %{params: unquote(warned)} = metadata
        assert metadata |> Map.keys() |> Enum.sort() == [:model, :params, :provider]
        refute inspect(metadata) =~ @user_id
      end
    end
  end

  test "an unsupported-feature warning names the features, not the call's metadata" do
    model = Models.init_chat_model!("fake:chat", responses: ["ok"], profile: %{provider: :fake, id: "plain"})

    assert {:ok, _reply} =
             ChatModel.invoke(model, "hi", reasoning_effort: :high, unsupported: :warn, metadata: %{user_id: @user_id})

    assert_receive {:telemetry, [:beam_weaver, :provider, :unsupported_feature], %{count: 1},
                    %{model: "plain"} = metadata}

    assert %{provider: :fake, features: [:reasoning]} = metadata
    assert metadata |> Map.keys() |> Enum.sort() == [:features, :model, :provider]
    refute inspect(metadata) =~ @user_id
  end
end
