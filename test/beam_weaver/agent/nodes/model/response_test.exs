defmodule BeamWeaver.Agent.Nodes.Model.ResponseTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Agent.Nodes.Model.Response
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message

  describe "attach_diagnostics/5 content clipping" do
    test "truncated multibyte content stays valid UTF-8 and serializable" do
      {details, content} = diagnosed("x" <> String.duplicate("é", 8_000))

      assert String.valid?(content)
      assert String.starts_with?(content, "xé")
      assert content =~ "truncated"
      assert {:ok, _encoded} = BeamWeaver.Serialization.dump_value(details)
    end

    test "ascii content under the limit is preserved unchanged" do
      assert {_details, "hello world"} = diagnosed("hello world")
    end
  end

  defp diagnosed(text) do
    message = Message.assistant(text)
    request = ModelRequest.new(model: "test-model", messages: [message])
    %Error{details: details} = Response.attach_diagnostics(Error.new(:model_error, "boom"), request, [message], [])
    {details, details.model_request.messages |> hd() |> Map.fetch!(:content)}
  end
end
