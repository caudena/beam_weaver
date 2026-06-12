defmodule BeamWeaver.TestSupport.Conformance.EmbeddingModelCaseTest do
  use BeamWeaver.TestSupport.Conformance.EmbeddingModelCase,
    model:
      {BeamWeaver.TestSupport.Conformance.Fakes.EmbeddingModel,
       [
         dimensions: 4,
         parent: :__beamweaver_self__,
         profile:
           BeamWeaver.Models.Profile.new(%{
             provider: :fake,
             id: "standard-embedding",
             supported_params: [:dimensions]
           })
       ]},
    capabilities: [:batch, :deterministic, :standard_params, :env_config_init],
    fixtures: %{
      dimensions: 4,
      standard_param_opts: [dimensions: 4],
      assert_forwarded_opts?: true,
      config: {:test_support, :fake_embedding_dimensions, "6"},
      env_builder: &BeamWeaver.TestSupport.Conformance.Fakes.EmbeddingModel.from_config/0
    }
end

defmodule BeamWeaver.TestSupport.Conformance.EmbeddingModelParamValidationCaseTest do
  use BeamWeaver.TestSupport.Conformance.EmbeddingModelCase,
    model:
      {BeamWeaver.TestSupport.Conformance.Fakes.EmbeddingModel,
       [
         dimensions: 4,
         profile:
           BeamWeaver.Models.Profile.new(%{
             provider: :fake,
             id: "strict-embedding",
             supported_params: []
           })
       ]},
    capabilities: [:param_validation]
end
