defmodule BeamWeaver.Agent.Nodes.Model.ResponseTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Agent.Nodes.Model.Response
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message

  describe "attach_diagnostics/5 content clipping" do
    test "truncated multibyte content stays valid UTF-8 and serializable" do
      long_content = "x" <> String.duplicate("é", 8_000)
      message = Message.assistant(long_content)
      request = ModelRequest.new(model: "test-model", messages: [message])
      error = Error.new(:model_error, "boom")

      %Error{details: details} = Response.attach_diagnostics(error, request, [message], [])

      content =
        details
        |> Map.fetch!(:model_request)
        |> Map.fetch!(:messages)
        |> hd()
        |> Map.fetch!(:content)

      assert String.valid?(content)
      assert String.starts_with?(content, "xé")
      assert content =~ "truncated"
      assert {:ok, _encoded} = BeamWeaver.Serialization.dump_json_value(details)
    end

    test "ascii content under the limit is preserved unchanged" do
      message = Message.assistant("hello world")
      request = ModelRequest.new(model: "test-model", messages: [message])
      error = Error.new(:model_error, "boom")

      %Error{details: details} = Response.attach_diagnostics(error, request, [message], [])

      content =
        details
        |> Map.fetch!(:model_request)
        |> Map.fetch!(:messages)
        |> hd()
        |> Map.fetch!(:content)

      assert content == "hello world"
    end
  end
end
