defmodule BeamWeaver.TestSupport.Conformance.LLMCaseTest do
  use BeamWeaver.TestSupport.Conformance.LLMCase,
    model:
      {BeamWeaver.TestSupport.Conformance.Fakes.LLM,
       [
         prefix: "done",
         stream_chunks: ["a", "b"],
         parent: :__beamweaver_self__,
         profile:
           BeamWeaver.Models.Profile.new(%{
             provider: :fake,
             id: "standard-llm",
             supported_params: [:temperature],
             streaming: true
           }),
         tokenizer: %BeamWeaver.Tokenizer.StaticVocabulary{
           vocabulary: %{"hello " => 1, "world" => 2}
         }
       ]},
    capabilities: [:batch, :streaming, :exact_tokenizer, :standard_params, :env_config_init],
    fixtures: %{
      expected_token_count: 2,
      standard_param_opts: [temperature: 0.1],
      assert_forwarded_opts?: true,
      config: {:test_support, :fake_llm_prefix, "env llm"},
      env_builder: &BeamWeaver.TestSupport.Conformance.Fakes.LLM.from_config/0
    }
end

defmodule BeamWeaver.TestSupport.Conformance.LLMParamValidationCaseTest do
  use BeamWeaver.TestSupport.Conformance.LLMCase,
    model:
      {BeamWeaver.TestSupport.Conformance.Fakes.LLM,
       [
         profile:
           BeamWeaver.Models.Profile.new(%{
             provider: :fake,
             id: "strict-llm",
             supported_params: []
           })
       ]},
    capabilities: [:param_validation]
end
