defmodule BeamWeaver.Agent.FinalResponsePolicyTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.FinalResponsePolicy

  test "structured mode extracts atom-keyed structured_response" do
    state = %{structured_response: %{"answer" => "ok"}}

    assert {:ok, %{"answer" => "ok"}} = FinalResponsePolicy.extract(:structured, state)
  end

  test "structured mode extracts string-keyed structured_response without crashing" do
    state = %{"structured_response" => %{"answer" => "ok"}}

    assert {:ok, %{"answer" => "ok"}} = FinalResponsePolicy.extract(:structured, state)
  end
end
