defmodule BeamWeaver.Runtime.ToolRunnerTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.OpenAI.Error, as: OpenAIError
  alias BeamWeaver.Runtime.Error
  alias BeamWeaver.Runtime.ToolRunner

  test "preserves structured provider errors" do
    provider_error =
      OpenAIError.new(:http_error, "provider rejected the request", %{
        status: 400,
        provider_code: "invalid_function_parameters"
      })

    assert {:error,
            %Error{
              type: :http_error,
              message: "provider rejected the request",
              details: %{
                status: 400,
                provider_code: "invalid_function_parameters"
              }
            }} = ToolRunner.run(:model, fn -> {:error, provider_error} end, nil, fn _ -> :ok end)
  end
end
