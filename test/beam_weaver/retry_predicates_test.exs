defmodule BeamWeaver.RetryPredicatesTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.RetryPredicates

  test "transient? honors a transient top-level :message even when details/type are not transient" do
    error = %{type: :some_error, details: %{}, message: "connection timed out"}
    assert RetryPredicates.transient?(error)
  end

  test "transient? stays false when neither details, type, nor message are transient" do
    error = %{type: :some_error, details: %{}, message: "bad request"}
    refute RetryPredicates.transient?(error)
  end

  test "transient? still detects transient details and types" do
    assert RetryPredicates.transient?(%{type: :timeout, details: %{}})
    assert RetryPredicates.transient?(%{type: :other, details: %{status: 503}})
  end
end
