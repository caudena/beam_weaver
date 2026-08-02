defmodule BeamWeaver.Provider.RedactedInspectTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Provider.RedactedInspect
  alias BeamWeaver.Transport.Redactor

  defmodule ExampleClient do
    defstruct [:api_key, :endpoint, :transport_opts]
  end

  test "renders provider structs while recursively redacting secrets" do
    client = %ExampleClient{
      api_key: "sk-provider-secret",
      endpoint: "https://example.test",
      transport_opts: [headers: [{"x-api-key", "nested-secret"}]]
    }

    rendered =
      client
      |> RedactedInspect.redacted_struct(%Inspect.Opts{limit: :infinity})
      |> Inspect.Algebra.format(100)
      |> IO.iodata_to_binary()

    assert rendered =~ "BeamWeaver.Provider.RedactedInspectTest.ExampleClient"
    assert rendered =~ "https://example.test"
    assert rendered =~ Redactor.redacted()
    refute rendered =~ "sk-provider-secret"
    refute rendered =~ "nested-secret"
  end
end
