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

  test "every library struct with a credential field redacts it when inspected" do
    {:ok, modules} = :application.get_key(:beam_weaver, :modules)

    secret_structs =
      for module <- modules,
          Code.ensure_loaded?(module),
          function_exported?(module, :__struct__, 0),
          Map.has_key?(module.__struct__(), :api_key),
          do: module

    assert BeamWeaver.Anthropic.Client in secret_structs

    for module <- secret_structs do
      rendered = inspect(struct(module, api_key: "sk-leak-check"), limit: :infinity)
      refute rendered =~ "sk-leak-check", "#{inspect(module)} leaks api_key through inspect/1"
    end
  end

  test "transport requests redact authorization headers when inspected" do
    request = %BeamWeaver.Transport.Request{
      method: :post,
      url: "https://example.test",
      headers: [{"authorization", "Bearer sk-header-secret"}]
    }

    refute inspect(request) =~ "sk-header-secret"
  end
end
