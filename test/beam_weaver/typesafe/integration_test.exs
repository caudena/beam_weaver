defmodule BeamWeaver.TypeSafe.IntegrationTest do
  use ExUnit.Case, async: false
  alias BeamWeaver.Core.{Async, DecisionModel}
  alias BeamWeaver.{Models, Runnable, Tracing}
  alias BeamWeaver.TestSupport.TypeSafe, as: Fixture

  defmodule Limiter do
    defstruct [:parent, allow: true]

    def acquire(limiter, _amount, _opts) do
      send(limiter.parent, :limit_checked)

      if limiter.allow,
        do: :ok,
        else: {:error, BeamWeaver.Core.Error.new(:rate_limited, "fixture limit")}
    end
  end

  setup do
    Tracing.reset()
    BeamWeaver.Tracing.Context.clear()

    on_exit(fn ->
      Tracing.reset()
      BeamWeaver.Tracing.Context.clear()
    end)

    :ok
  end

  test "configuration fallback and explicit nil credentials follow provider conventions" do
    BeamWeaver.TestSupport.ConfigHelper.put_config(:typesafe,
      api_key: "configured-secret",
      base_url: "https://gateway.test"
    )

    assert {:ok, model} = Models.init_decision_model("typesafe:jev-latest")
    assert model.client.http.api_key == "configured-secret"
    assert model.client.http.endpoint == "https://gateway.test/v1/systemone"
    assert Models.init_decision_model!("typesafe:jev-latest", api_key: nil).client.http.api_key == nil
  end

  test "rate-limited decisions acquire before requests and compose with caching" do
    limiter = %Limiter{parent: self()}
    cache = BeamWeaver.Cache.ETS.new(visibility: :private)
    model = Fixture.model() |> Models.with_rate_limiter(limiter: limiter) |> Models.cached(cache)
    assert {:ok, first} = Runnable.invoke(model, Fixture.input())
    assert {:ok, cached} = Runnable.invoke(model, Fixture.input())
    assert first.answers == cached.answers
    assert cached.usage.total_tokens == 0
    assert_receive :limit_checked
    refute_received :limit_checked
    assert_receive {:typesafe_request, _}
    refute_received {:typesafe_request, _}

    blocked = Models.with_rate_limiter(Fixture.model(), limiter: %{limiter | allow: false})
    assert {:error, %{type: :rate_limited}} = DecisionModel.invoke(blocked, Fixture.input())
    assert_receive :limit_checked
    refute_received {:typesafe_request, _}
  end

  test "sync, async and batch decisions have sibling model spans with usage and redacted inputs" do
    {:ok, parent} = Tracing.start_run("parent", kind: :chain)
    model = Fixture.model()
    input = put_in(Fixture.input(), [:state, :api_key], "sensitive-state-secret")
    assert {:ok, _} = DecisionModel.invoke(model, input)
    assert {:ok, _} = model |> DecisionModel.async_invoke(input) |> Async.await()
    assert {:ok, [_, _]} = DecisionModel.batch(model, [input, input], max_concurrency: 2)
    assert {:ok, stream} = Runnable.batch_as_completed(model, [input, input], max_concurrency: 2)
    assert length(Enum.to_list(stream)) == 2
    assert Tracing.capture_context().run_id == parent.id
    Tracing.finish_run(parent)

    runs = BeamWeaver.Tracing.Store.list() |> Enum.filter(&(&1.kind == :model))
    assert length(runs) == 6

    for run <- runs do
      assert run.parent_id == parent.id
      assert run.status == :ok
      assert run.usage.total_tokens == 120
      assert run.metadata.provider == "typesafe"
      assert run.metadata.model == "jev-1.13.0"
      assert run.metadata.request_id == "req-fixture"
      refute inspect(run, limit: :infinity) =~ "sensitive-state-secret"
      refute inspect(run, limit: :infinity) =~ "fixture-secret"
      exported = BeamWeaver.Tracing.Exporters.WeaveScope.to_event(:ok, run)
      assert exported["model_provider"] == "typesafe"
      assert exported["model_name"] == "jev-1.13.0"
      assert exported["usage"][:total_tokens] == 120
    end
  end

  test "failed decisions retain error spans and restore their parent context" do
    {:ok, parent} = Tracing.start_run("parent", kind: :chain)
    model = Fixture.model(respond: fn _ -> {:error, BeamWeaver.Transport.Error.new(:timeout, "timeout")} end)
    assert {:error, _} = DecisionModel.invoke(model, Fixture.input())
    assert Tracing.capture_context().run_id == parent.id
    runs = BeamWeaver.Tracing.Store.list() |> Enum.filter(&(&1.kind == :model))
    assert [%{status: :error, parent_id: id, error: %{type: :transport_error}}] = runs
    assert id == parent.id
    Tracing.finish_run(parent)
  end
end
