defmodule BeamWeaver.Provider.BillingSnapshotTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Provider.BillingSnapshot

  test "OpenAI snapshot retains billing units and pagination without resource contents" do
    request = fn options ->
      body =
        if String.ends_with?(options[:url], "/containers") do
          %{
            "data" => [
              %{
                "id" => "cntr_probe",
                "memory_limit" => "1g",
                "created_at" => 1_790_637_465,
                "last_active_at" => 1_790_637_914,
                "status" => "running",
                "secret" => "must-not-appear"
              }
            ],
            "has_more" => true
          }
        else
          %{
            "data" => [%{"id" => "vs_probe", "usage_bytes" => 2_048, "created_at" => 1_790_637_988}],
            "has_more" => false
          }
        end

      {:ok, %Req.Response{status: 200, body: body}}
    end

    assert {:ok, snapshot} = BillingSnapshot.fetch(:openai, api_key: "test-secret", request_fun: request)

    assert snapshot.containers.data == [
             %{
               id: "cntr_probe",
               memory_limit: "1g",
               created_at: 1_790_637_465,
               last_active_at: 1_790_637_914,
               status: "running"
             }
           ]

    assert snapshot.containers.next_after == "cntr_probe"

    assert snapshot.vector_stores.data == [
             %{id: "vs_probe", usage_bytes: 2_048, created_at: 1_790_637_988, status: nil}
           ]

    refute inspect(snapshot) =~ "test-secret"
    refute inspect(snapshot) =~ "must-not-appear"
  end

  test "Google and Anthropic snapshots keep cache token-hours and session cumulative cost" do
    google_request = fn _options ->
      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "cachedContents" => [
             %{
               "name" => "cachedContents/probe",
               "model" => "models/gemini-3.8-flash",
               "createTime" => "2026-09-28T23:20:00Z",
               "expireTime" => "2026-09-28T23:21:00Z",
               "usageMetadata" => %{"totalTokenCount" => 49_893},
               "contents" => ["must-not-appear"]
             }
           ],
           "nextPageToken" => "next"
         }
       }}
    end

    assert {:ok, google} = BillingSnapshot.fetch(:google, api_key: "secret", request_fun: google_request)
    assert google.caches.next_page == "next"
    assert [%{total_token_count: 49_893}] = google.caches.data
    refute inspect(google) =~ "must-not-appear"

    anthropic_request = fn _options ->
      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "data" => [
             %{
               "id" => "sesn_probe",
               "status" => "idle",
               "usage" => %{
                 "active_seconds" => 342.5,
                 "list_cost" => %{"amount" => "187", "currency" => "USD"}
               },
               "agent" => %{"system" => "must-not-appear"}
             }
           ]
         }
       }}
    end

    assert {:ok, anthropic} =
             BillingSnapshot.fetch(:anthropic, api_key: "secret", request_fun: anthropic_request)

    assert anthropic.sessions.data == [
             %{
               id: "sesn_probe",
               status: "idle",
               updated_at: nil,
               active_seconds: 342.5,
               list_cost_cents: "187",
               currency: "USD"
             }
           ]

    refute inspect(anthropic) =~ "must-not-appear"
  end
end
