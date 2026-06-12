defmodule BeamWeaver.TestSupport.Conformance.ChatModelCaseTest do
  use BeamWeaver.TestSupport.Conformance.ChatModelCase,
    subject: %BeamWeaver.TestSupport.Conformance.Subject{
      build:
        {BeamWeaver.TestSupport.Conformance.Fakes.ChatModel,
         [
           reply: "pong",
           usage_metadata: %{input_tokens: 1, output_tokens: 1, total_tokens: 2},
           stream_chunks: [BeamWeaver.Core.Message.assistant("stream pong")],
           profile:
             BeamWeaver.Models.Profile.new(%{
               provider: :fake,
               id: "standard-chat",
               supported_params: [:tools],
               streaming: true,
               usage_metadata: true,
               tool_calling: true
             }),
           tokenizer: %BeamWeaver.Tokenizer.StaticVocabulary{
             vocabulary: %{"hello " => 11, "world" => 12}
           },
           tool_calls: [%{id: "call_lookup", name: "lookup", args: %{query: "hello"}}]
         ]},
      capabilities: [
        :streaming,
        :usage_metadata,
        :tool_calling,
        :exact_tokenizer,
        :param_validation
      ],
      fixtures: %{expected_token_count: 2}
    }
end

defmodule BeamWeaver.TestSupport.Conformance.ChatModelCaseEdgeTest do
  use BeamWeaver.TestSupport.Conformance.ChatModelCase,
    subject: %BeamWeaver.TestSupport.Conformance.Subject{
      build:
        {BeamWeaver.TestSupport.Conformance.Fakes.ChatModel,
         [
           reply: "edge",
           parent: :__beamweaver_self__,
           usage_metadata: %{
             input_tokens: 2,
             output_tokens: 3,
             total_tokens: 5,
             input_token_details: %{cache_read: 1, cache_creation: 1},
             output_token_details: %{reasoning: 2, audio: 1}
           },
           stream_chunks: BeamWeaver.TestSupport.Conformance.Fakes.ChatModel.streamed_invalid_tool_call(),
           profile:
             BeamWeaver.Models.Profile.new(%{
               provider: :fake,
               id: "standard-chat-edge",
               supported_params: [:tools, :model, :response_format],
               streaming: true,
               usage_metadata: true,
               tool_calling: true,
               parallel_tool_calls: true,
               structured_output: true
             }),
           structured_response: %{"value" => "native"},
           stream_events: BeamWeaver.TestSupport.Conformance.Fakes.ChatModel.lifecycle_stream_events("edge"),
           tool_calls: [
             %{id: "call_lookup", name: "lookup", args: %{query: "hello"}},
             %{id: "call_time", name: "time", args: %{zone: "UTC"}}
           ]
         ]},
      capabilities: [
        :streaming,
        :stream_events,
        :stream_lifecycle,
        :usage_metadata,
        :usage_details,
        :parallel_tool_calls,
        :structured_output,
        :standard_params,
        :model_override,
        :env_config_init,
        :message_histories,
        :multimodal_inputs,
        :invalid_streamed_tool_call
      ],
      fixtures: %{
        standard_param_opts: [model: "override-model", response_format: %{type: "json_object"}],
        assert_forwarded_opts?: true,
        config: {:test_support, :fake_chat_reply, "env edge"},
        env_builder: &BeamWeaver.TestSupport.Conformance.Fakes.ChatModel.from_config/0
      }
    }
end

defmodule BeamWeaver.TestSupport.Conformance.ChatModelToolChoiceCaseTest do
  use BeamWeaver.TestSupport.Conformance.ChatModelCase,
    subject: %BeamWeaver.TestSupport.Conformance.Subject{
      build:
        {BeamWeaver.TestSupport.Conformance.Fakes.ChatModel,
         [
           reply: "tool choice",
           parent: :__beamweaver_self__,
           profile:
             BeamWeaver.Models.Profile.new(%{
               provider: :fake,
               id: "standard-chat-tool-choice",
               supported_params: [:tools, :tool_choice],
               tool_calling: true,
               tool_choice: true
             }),
           tool_calls: :from_tools
         ]},
      capabilities: [:tool_calling, :tool_choice],
      fixtures: %{assert_forwarded_opts?: true}
    }
end
