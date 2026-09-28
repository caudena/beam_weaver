defmodule BeamWeaver.ProviderBillingLive do
  @moduledoc """
  Opt-in live billing-metadata probe. Run with one case and the matching provider
  API key in the environment. Prints selected response fields, never credentials
  or image bytes. This script is intentionally outside the normal test suite.
  """

  alias BeamWeaver.Core.ChatModel, as: CoreChatModel
  alias BeamWeaver.Core.Message

  def run(["--", case_name]), do: run([case_name])
  def run(["--", "openai-delete-container", id]), do: run(["openai-delete-container", id])

  def run(["openai-delete-container", "cntr_" <> _rest = id]) do
    key = key!("OPENAI_API_KEY")
    url = "https://api.openai.com/v1/containers/" <> id
    response = Req.delete(url: url, headers: [{"authorization", "Bearer " <> key}])

    result =
      case response do
        {:ok, reply} -> %{status: reply.status, deleted: reply.body["deleted"]}
        {:error, error} -> %{error: safe_error(error)}
      end

    IO.puts(Jason.encode!(%{case: "openai-delete-container", result: result}, pretty: true))
  end

  def run([case_name]) do
    result =
      case case_name do
        "openai-preview" -> openai_preview()
        "openai-image-tool" -> openai_image_tool()
        "openai-images-api" -> openai_images_api()
        "openai-code" -> openai_code()
        "openai-resources" -> openai_resources()
        "openai-vector-store-lifecycle" -> openai_vector_store_lifecycle()
        "google-search" -> google_search()
        "google-maps" -> google_maps()
        "google-caches" -> google_caches()
        "google-cache-lifecycle" -> google_cache_lifecycle()
        "anthropic-code" -> anthropic_code()
        "anthropic-sessions" -> anthropic_sessions()
        _ -> raise "unknown probe case: #{case_name}"
      end

    IO.puts(Jason.encode!(%{case: case_name, observed_at: DateTime.utc_now(), result: result}, pretty: true))
  end

  def run(_args) do
    raise "usage: mix run scripts/provider_billing_live.exs -- CASE"
  end

  defp openai_preview do
    {:ok, profile} = BeamWeaver.Models.ProfileRegistry.fetch(:openai, "gpt-5.4-mini")
    profile = %{profile | id: "gpt-4.1-mini", name: "GPT-4.1 mini", reasoning_output: false}

    model = BeamWeaver.OpenAI.ChatModel.new(model: "gpt-4.1-mini", profile: profile, api_key: key!("OPENAI_API_KEY"))

    invoke(model, "Search the web for the current UTC date. Answer with the date only.",
      tools: [BeamWeaver.OpenAI.ToolCalling.web_search()]
    )
  end

  defp openai_image_tool do
    model = BeamWeaver.OpenAI.ChatModel.new(model: "gpt-6-astra", api_key: key!("OPENAI_API_KEY"), timeout: 90_000)

    invoke(model, "Generate one simple blue square on a white background.",
      tools: [
        BeamWeaver.OpenAI.ToolCalling.image_generation(model: "gpt-image-2.5-flare", quality: "low", size: "1024x1024")
      ]
    )
  end

  defp openai_images_api do
    case BeamWeaver.OpenAI.generate_image("A simple blue square on white.",
           model: "gpt-image-2.5-flare",
           api_key: key!("OPENAI_API_KEY"),
           quality: "low",
           size: "1024x1024",
           timeout: 90_000
         ) do
      {:ok, payload} ->
        run =
          BeamWeaver.Tracing.Store.list()
          |> Enum.find(&(&1.name == "openai:gpt-image-2.5-flare:images"))

        %{
          status: 200,
          usage: payload["usage"],
          image_count: length(payload["data"] || []),
          trace_usage: run && run.usage,
          trace_metadata: run && Map.take(run.metadata, [:model_provider, :model_name, :api]),
          trace_outputs: run && run.outputs
        }

      {:error, error} ->
        %{error: safe_error(error)}
    end
  end

  defp openai_code do
    model = BeamWeaver.OpenAI.ChatModel.new(model: "gpt-5.4-mini", api_key: key!("OPENAI_API_KEY"), timeout: 60_000)

    result =
      invoke(model, "Use the code interpreter to calculate 2 + 2. Answer with the number.",
        tools: [BeamWeaver.OpenAI.ToolCalling.code_interpreter()],
        tool_choice: %{"type" => "code_interpreter"}
      )

    containers =
      result
      |> Map.get(:raw_output_items, [])
      |> Enum.map(& &1["container_id"])
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    deleted =
      Enum.map(containers, fn id ->
        key = key!("OPENAI_API_KEY")
        url = "https://api.openai.com/v1/containers/" <> id

        case Req.delete(url: url, headers: [{"authorization", "Bearer " <> key}]) do
          {:ok, reply} -> %{id: id, status: reply.status, deleted: reply.body["deleted"]}
          {:error, error} -> %{id: id, error: safe_error(error)}
        end
      end)

    Map.put(result, :deleted_containers, deleted)
  end

  defp google_search do
    model = BeamWeaver.Google.ChatModel.new(model: "gemini-3.8-flash", api_key: key!("GOOGLE_API_KEY"), timeout: 60_000)

    invoke(model, "Use Google Search to find the current Bitcoin price in USD and cite the source URL.",
      tools: [BeamWeaver.Google.Tools.google_search()]
    )
  end

  defp google_maps do
    model = BeamWeaver.Google.ChatModel.new(model: "gemini-3.8-flash", api_key: key!("GOOGLE_API_KEY"), timeout: 60_000)

    invoke(model, "Use Google Maps to identify one public museum in Nicosia, Cyprus. Give its name only.",
      tools: [BeamWeaver.Google.Tools.google_maps()]
    )
  end

  defp anthropic_code do
    model =
      BeamWeaver.Anthropic.ChatModel.new(
        model: "claude-haiku-4-5-20251001",
        api_key: key!("ANTHROPIC_API_KEY"),
        max_tokens: 512,
        timeout: 90_000,
        betas: ["code-execution-2025-05-22"]
      )

    invoke(model, "Use code execution to print 2 + 2. Answer with the number.",
      tools: [BeamWeaver.Anthropic.Tools.code_execution()]
    )
  end

  defp openai_resources do
    case BeamWeaver.Provider.BillingSnapshot.fetch(:openai, api_key: key!("OPENAI_API_KEY"), limit: 1) do
      {:ok, snapshot} -> snapshot
      {:error, error} -> %{error: error}
    end
  end

  defp openai_vector_store_lifecycle do
    url = "https://api.openai.com/v1/vector_stores"
    headers = [{"authorization", "Bearer " <> key!("OPENAI_API_KEY")}]

    case Req.post(url: url, headers: headers, json: %{name: "beam-weaver-billing-probe"}) do
      {:ok, %{status: 200, body: %{"id" => id} = store}} ->
        delete = Req.delete(url: url <> "/" <> id, headers: headers)

        %{
          create_status: 200,
          id: id,
          usage_bytes: store["usage_bytes"],
          created_at: store["created_at"],
          delete_status:
            case delete do
              {:ok, response} -> response.status
              {:error, _error} -> :error
            end
        }

      {:ok, response} ->
        %{create_status: response.status, error: Map.get(response.body, "error")}

      {:error, error} ->
        %{error: safe_error(error)}
    end
  end

  defp google_caches do
    case BeamWeaver.Provider.BillingSnapshot.fetch(:google, api_key: key!("GOOGLE_API_KEY"), limit: 1) do
      {:ok, snapshot} -> snapshot
      {:error, error} -> %{error: error}
    end
  end

  defp google_cache_lifecycle do
    url = "https://generativelanguage.googleapis.com/v1beta/cachedContents"
    headers = [{"x-goog-api-key", key!("GOOGLE_API_KEY")}]

    content =
      1..3_000
      |> Enum.map_join("\n", fn number -> "Line #{number}: A blue square is a simple geometric shape." end)

    body = %{
      model: "models/gemini-3.8-flash",
      contents: [%{role: "user", parts: [%{text: content}]}],
      ttl: "60s"
    }

    case Req.post(url: url, headers: headers, json: body, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: %{"name" => name} = cache}} ->
        delete = Req.delete(url: "https://generativelanguage.googleapis.com/v1beta/" <> name, headers: headers)

        delete_status =
          case delete do
            {:ok, response} -> response.status
            {:error, _error} -> :error
          end

        %{
          create_status: 200,
          name: name,
          model: cache["model"],
          create_time: cache["createTime"],
          expire_time: cache["expireTime"],
          usage_metadata: cache["usageMetadata"],
          delete_status: delete_status
        }

      {:ok, response} ->
        %{create_status: response.status, error: Map.get(response.body, "error")}

      {:error, error} ->
        %{error: safe_error(error)}
    end
  end

  defp anthropic_sessions do
    case BeamWeaver.Provider.BillingSnapshot.fetch(:anthropic, api_key: key!("ANTHROPIC_API_KEY"), limit: 1) do
      {:ok, snapshot} -> snapshot
      {:error, error} -> %{error: error}
    end
  end

  defp invoke(model, prompt, opts) do
    case CoreChatModel.invoke(model, [Message.user(prompt)], opts) do
      {:ok, message} ->
        metadata = message.response_metadata || %{}
        tooling = metadata[:tooling] || %{}
        hosted = tooling[:hosted] || %{}
        grounding = metadata[:grounding] || %{}
        raw_usage = metadata[:usage] || %{}
        raw_response = metadata[:raw_provider_response] || %{}
        content_items =
          case Message.content_blocks(message) do
            {:ok, blocks} -> Enum.map(blocks, &Map.take(&1, [:type, :id, :status, :container_id, :provider_type]))
            _other -> []
          end

        %{
          answer: message |> Message.text() |> to_string() |> String.slice(0, 300),
          usage: message.usage_metadata,
          hosted_usage: hosted[:usage],
          hosted_calls:
            Enum.map(hosted[:calls] || [], &Map.take(&1, [:type, :id, :status, :container_id, :name, :action])),
          grounding: summarize_grounding(grounding),
          container: metadata[:container],
          model: metadata[:model],
          raw_server_tool_use: raw_usage[:server_tool_use] || raw_usage["server_tool_use"],
          raw_output_items:
            Enum.map(raw_response["output"] || [], &Map.take(&1, ["type", "id", "status", "container_id", "name"])),
          content_items: content_items
        }

      {:error, error} ->
        %{error: safe_error(error)}
    end
  end

  defp summarize_grounding(grounding) do
    raw = grounding[:grounding_metadata] || %{}
    chunks = raw["groundingChunks"] || raw["grounding_chunks"] || []

    %{
      web_search_queries: grounding[:web_search_queries],
      chunk_types: Enum.map(chunks, &Map.keys/1),
      search_entry_point?: Map.has_key?(raw, "searchEntryPoint")
    }
  end

  defp safe_error(error) when is_map(error),
    do: Map.take(error, [:type, :message, :status, :status_code, :code])

  defp safe_error(error), do: %{type: inspect(error)}

  defp key!(name), do: System.fetch_env!(name)
end

BeamWeaver.ProviderBillingLive.run(System.argv())
