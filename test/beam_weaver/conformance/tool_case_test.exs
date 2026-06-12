defmodule BeamWeaver.TestSupport.Conformance.ToolCaseTest do
  use BeamWeaver.TestSupport.Conformance.ToolCase,
    tool: &BeamWeaver.TestSupport.Conformance.Fakes.Tools.adder/0,
    input: %{a: 1, b: 2},
    capabilities: [:provider_rendering]
end

defmodule BeamWeaver.TestSupport.Conformance.ToolCaseInjectedArgsTest do
  use BeamWeaver.TestSupport.Conformance.ToolCase,
    tool: &BeamWeaver.TestSupport.Conformance.Fakes.Tools.injected/0,
    input: %{query: "hello"},
    capabilities: [:injected_args, :provider_rendering]
end

defmodule BeamWeaver.TestSupport.Conformance.ToolCaseArtifactTest do
  use BeamWeaver.TestSupport.Conformance.ToolCase,
    tool: &BeamWeaver.TestSupport.Conformance.Fakes.Tools.artifact_tool/0,
    input: %{query: "hello"},
    capabilities: [:artifacts, :provider_rendering]
end

defmodule BeamWeaver.TestSupport.Conformance.ToolCaseNestedSchemaTest do
  use BeamWeaver.TestSupport.Conformance.ToolCase,
    tool: &BeamWeaver.TestSupport.Conformance.Fakes.Tools.nested_schema_tool/0,
    input: %{items: [%{name: "bolt", quantity: 2, unit: nil}]},
    capabilities: [:nested_schema, :provider_rendering],
    fixtures: %{nested_invalid_input: %{items: [%{name: "bolt", quantity: "two"}]}}
end

defmodule BeamWeaver.TestSupport.Conformance.ToolCaseProviderNameValidationTest do
  use BeamWeaver.TestSupport.Conformance.ToolCase,
    tool: &BeamWeaver.TestSupport.Conformance.Fakes.Tools.unsafe_provider_name_tool/0,
    input: %{},
    capabilities: [:provider_name_validation]
end
