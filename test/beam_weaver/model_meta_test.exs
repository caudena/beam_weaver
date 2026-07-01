defmodule BeamWeaver.ModelMetaTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.TestSupport.ModelMeta
  alias BeamWeaver.Transport.Request
  alias BeamWeaver.Transport.Response

  test "sanitizer redacts auth headers and preserves non-secret provider headers" do
    request =
      Request.new(
        method: :post,
        url: "https://api.example.test/v1/messages?api_key=secret",
        headers: [
          {"authorization", "Bearer secret-token"},
          {"content-type", "application/json"},
          {"user-agent", "beam-weaver"},
          {"x-api-key", "secret-key"},
          {"x-goog-api-key", "google-secret"},
          {"request-id", "req_123"},
          {"anthropic-organization-id", "org_123"},
          {"anthropic-ratelimit-requests-remaining", "42"}
        ],
        json: %{
          "api_key" => "secret",
          "request_id" => "req_body",
          "usage" => %{"input_tokens" => 12, "output_tokens" => 5}
        }
      )

    sanitized = ModelMeta.sanitize_request(request)

    assert ["authorization", ModelMeta.redacted()] in sanitized["headers"]
    assert ["x-api-key", ModelMeta.redacted()] in sanitized["headers"]
    assert ["x-goog-api-key", ModelMeta.redacted()] in sanitized["headers"]
    assert ["request-id", "req_123"] in sanitized["headers"]
    assert ["anthropic-organization-id", "org_123"] in sanitized["headers"]
    assert ["anthropic-ratelimit-requests-remaining", "42"] in sanitized["headers"]
    refute Enum.any?(sanitized["headers"], &match?(["content-type", _value], &1))
    refute Enum.any?(sanitized["headers"], &match?(["user-agent", _value], &1))
    assert sanitized["url"] =~ "api_key=#{ModelMeta.redacted()}"
    assert sanitized["json"]["api_key"] == ModelMeta.redacted()
    assert sanitized["json"]["request_id"] == "req_body"
    assert sanitized["json"]["usage"]["input_tokens"] == 12
    assert sanitized["json"]["usage"]["output_tokens"] == 5
  end

  test "sanitizer redacts credential-looking provider error tokens inside strings" do
    assert ModelMeta.sanitize_value("account <ak-faf7o133xufi11cfscki> needs billing") ==
             "account <#{ModelMeta.redacted()}> needs billing"
  end

  test "sanitizer preserves response ids and rate-limit values" do
    response =
      Response.new(
        status: 200,
        headers: [
          {"cf-ray", "abc"},
          {"content-type", "application/json"},
          {"date", "Wed, 01 Jul 2026 00:00:00 GMT"},
          {"set-cookie", "sid=secret"},
          {"x-request-id", "req_live"},
          {"openai-organization", "org_live"},
          {"x-ratelimit-remaining-tokens", "999"}
        ],
        body: %{
          "id" => "resp_123",
          "created_at" => "2026-07-01T10:00:00Z",
          "usage" => %{"input_tokens" => 1, "output_tokens" => 2}
        }
      )

    sanitized = ModelMeta.sanitize_response(response)

    assert ["x-request-id", "req_live"] in sanitized["headers"]
    assert ["openai-organization", "org_live"] in sanitized["headers"]
    assert ["x-ratelimit-remaining-tokens", "999"] in sanitized["headers"]
    refute Enum.any?(sanitized["headers"], &match?(["cf-ray", _value], &1))
    refute Enum.any?(sanitized["headers"], &match?(["content-type", _value], &1))
    refute Enum.any?(sanitized["headers"], &match?(["date", _value], &1))
    refute Enum.any?(sanitized["headers"], &match?(["set-cookie", _value], &1))
    assert sanitized["body"]["id"] == "resp_123"
    assert sanitized["body"]["created_at"] == "2026-07-01T10:00:00Z"
    assert sanitized["body"]["usage"]["input_tokens"] == 1
  end

  test "sanitizer filters nested provider header maps to LLM metadata headers" do
    sanitized =
      ModelMeta.sanitize_term(%{
        "headers" => %{
          "anthropic-ratelimit-requests-remaining" => "42",
          "cf-cache-status" => "DYNAMIC",
          "content-type" => "application/json",
          "request-id" => "req_123"
        },
        "raw_provider_response" => %{
          "_beamweaver_response_headers" => %{
            "date" => "Wed, 01 Jul 2026 00:00:00 GMT",
            "msh-request-id" => "msh_req",
            "server" => "cloudflare",
            "x-msh-trace-id" => "trace_123"
          }
        }
      })

    assert sanitized["headers"] == %{
             "anthropic-ratelimit-requests-remaining" => "42",
             "request-id" => "req_123"
           }

    assert sanitized["raw_provider_response"]["_beamweaver_response_headers"] == %{
             "msh-request-id" => "msh_req",
             "x-msh-trace-id" => "trace_123"
           }
  end

  test "manifest diff reports added removed and type changes but ignores value categories" do
    old_manifest = %{
      "entries" => [
        entry("response_headers", "/x-request-id", "string", "id_like"),
        entry("response_body", "/usage/input_tokens", "integer", "integer"),
        entry("response_body", "/service_tier", "string", "string"),
        entry("response_body", "/removed", "string", "string")
      ]
    }

    new_manifest = %{
      "entries" => [
        entry("response_headers", "/x-request-id", "string", "id_like"),
        entry("response_headers", "/new-header", "string", "string"),
        entry("response_body", "/usage/input_tokens", "string", "string"),
        entry("response_body", "/service_tier", "string", "id_like")
      ]
    }

    diff = ModelMeta.diff_manifests(old_manifest, new_manifest)

    assert diff["summary"]["added"] == 1
    assert diff["summary"]["removed"] == 1
    assert diff["summary"]["type_changes"] == 1
    refute Map.has_key?(diff["summary"], "category_changes")
    refute Map.has_key?(diff, "category_changes")

    assert [%{"path" => "/new-header"}] = diff["added"]
    assert [%{"path" => "/removed"}] = diff["removed"]

    assert [%{"path" => "/usage/input_tokens", "old_value_type" => "integer", "new_value_type" => "string"}] =
             diff["type_changes"]
  end

  test "manifest diff ignores volatile value changes when field shape is stable" do
    old_manifest = %{"entries" => [entry("response_headers", "/x-request-id", "string", "id_like")]}
    new_manifest = %{"entries" => [entry("response_headers", "/x-request-id", "string", "id_like")]}

    diff = ModelMeta.diff_manifests(old_manifest, new_manifest)

    assert diff["summary"] == %{
             "added" => 0,
             "removed" => 0,
             "type_changes" => 0,
             "mapping_status_changes" => 0
           }
  end

  test "fixture inventory tracks provider fields and exported mapping status" do
    fixture = %{
      "provider" => "anthropic",
      "model" => "claude-sonnet-5",
      "scenario" => "basic_chat",
      "interactions" => [
        %{
          "request" => %{"headers" => [["x-api-key", ModelMeta.redacted()]]},
          "response" => %{
            "headers" => [["request-id", "req_1"]],
            "body" => %{
              "model" => "claude-sonnet-5",
              "usage" => %{"input_tokens" => 1},
              "new_provider_field" => true
            }
          }
        }
      ],
      "beamweaver_result" => %{
        "usage_metadata" => %{"input_tokens" => 1},
        "response_metadata" => %{"model" => %{"model" => "claude-sonnet-5"}}
      },
      "weavescope_events" => [%{"model_name" => "claude-sonnet-5", "usage" => %{"input_tokens" => 1}}]
    }

    entries = ModelMeta.fixture_inventory(fixture)

    assert Enum.any?(entries, &(&1["source"] == "response_headers" and &1["path"] == "/request-id"))
    assert Enum.any?(entries, &(&1["source"] == "response_body" and &1["path"] == "/usage/input_tokens"))

    assert Enum.any?(
             entries,
             &(&1["source"] == "response_body" and &1["path"] == "/new_provider_field" and
                 &1["mapping_status"] == "provider_only")
           )
  end

  test "fixture inventory includes nested metadata from compound results" do
    fixture = %{
      "provider" => "anthropic",
      "model" => "claude-sonnet-5",
      "scenario" => "prompt_cache_two_call",
      "interactions" => [],
      "beamweaver_result" => %{
        "status" => "ok",
        "value" => %{
          "first" => %{
            "usage_metadata" => %{"input_token_details" => %{"cache_read" => 10}},
            "response_metadata" => %{"usage" => %{"cache_read_tokens" => 10}}
          },
          "second" => %{
            "usage_metadata" => %{"input_token_details" => %{"cache_read" => 20}},
            "response_metadata" => %{"usage" => %{"cache_creation_input_tokens" => 5}}
          }
        }
      },
      "weavescope_events" => []
    }

    entries = ModelMeta.fixture_inventory(fixture)

    assert Enum.any?(
             entries,
             &(&1["source"] == "usage_metadata" and
                 &1["path"] == "/value/first/input_token_details/cache_read")
           )

    assert Enum.any?(
             entries,
             &(&1["source"] == "response_metadata" and
                 &1["path"] == "/value/second/usage/cache_creation_input_tokens")
           )
  end

  test "fixture inventory reuses stored field inventory without recomputing from values" do
    fixture = %{
      "provider" => "openai",
      "model" => "gpt-5.5",
      "scenario" => "streaming",
      "interactions" => [
        %{
          "response" => %{
            "headers" => [["x-request-id", "req_new_value"]],
            "body" => %{"new_value_only_field" => true}
          }
        }
      ],
      "field_inventory" => [
        entry("response_headers", "/x-request-id", "string", "id_like"),
        entry("response_headers", "/x-request-id", "string", "id_like"),
        entry("response_sse", "/events/*/type", "string", "string")
      ]
    }

    assert [
             {"response_headers", "/x-request-id"},
             {"response_sse", "/events/*/type"}
           ] =
             fixture
             |> ModelMeta.fixture_inventory()
             |> Enum.map(&{&1["source"], &1["path"]})
             |> Enum.sort()
  end

  defp entry(source, path, type, category) do
    %{
      "provider" => "anthropic",
      "model" => "claude-sonnet-5",
      "scenario" => "basic_chat",
      "source" => source,
      "path" => path,
      "value_type" => type,
      "value_category" => category,
      "mapping_status" => "observed"
    }
  end
end
