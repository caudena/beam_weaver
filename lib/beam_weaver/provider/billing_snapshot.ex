defmodule BeamWeaver.Provider.BillingSnapshot do
  @moduledoc """
  Read-only snapshots of provider resources with account-level billing units.

  Snapshots expose current resources, not historical invoices. Pollers should
  retain each snapshot and follow pagination cursors. Deleted resources between
  polls and provider-wide free allowances cannot be reconstructed from one
  snapshot. No API key or resource contents are returned.
  """

  alias BeamWeaver.Config

  @openai_base "https://api.openai.com/v1"
  @google_base "https://generativelanguage.googleapis.com/v1beta"
  @anthropic_base "https://api.anthropic.com/v1"

  @doc "Fetch one page of OpenAI containers/vector stores, Gemini caches, or Claude sessions."
  def fetch(:openai, opts) when is_list(opts) do
    with {:ok, key} <- api_key(opts, :openai),
         headers = [{"authorization", "Bearer " <> key}],
         {:ok, containers} <-
           get(@openai_base <> "/containers", headers,
             limit: Keyword.get(opts, :limit, 100),
             after: Keyword.get(opts, :container_after),
             request_fun: Keyword.get(opts, :request_fun, &Req.get/1)
           ),
         {:ok, stores} <-
           get(@openai_base <> "/vector_stores", headers,
             limit: Keyword.get(opts, :limit, 100),
             after: Keyword.get(opts, :vector_store_after),
             request_fun: Keyword.get(opts, :request_fun, &Req.get/1)
           ) do
      {:ok,
       %{
         provider: "openai",
         observed_at: DateTime.utc_now(),
         containers: page(containers, &openai_container/1),
         vector_stores: page(stores, &openai_vector_store/1)
       }}
    end
  end

  def fetch(:google, opts) when is_list(opts) do
    with {:ok, key} <- api_key(opts, :google),
         {:ok, body} <-
           get(@google_base <> "/cachedContents", [{"x-goog-api-key", key}],
             pageSize: Keyword.get(opts, :limit, 100),
             pageToken: Keyword.get(opts, :page_token),
             request_fun: Keyword.get(opts, :request_fun, &Req.get/1)
           ) do
      {:ok,
       %{
         provider: "google",
         observed_at: DateTime.utc_now(),
         caches: %{
           data: Enum.map(body["cachedContents"] || [], &google_cache/1),
           next_page: body["nextPageToken"]
         }
       }}
    end
  end

  def fetch(:anthropic, opts) when is_list(opts) do
    with {:ok, key} <- api_key(opts, :anthropic),
         {:ok, body} <-
           get(
             @anthropic_base <> "/sessions",
             [
               {"x-api-key", key},
               {"anthropic-version", "2023-06-01"},
               {"anthropic-beta", "managed-agents-2026-04-01"}
             ],
             limit: Keyword.get(opts, :limit, 100),
             page: Keyword.get(opts, :page),
             request_fun: Keyword.get(opts, :request_fun, &Req.get/1)
           ) do
      {:ok,
       %{
         provider: "anthropic",
         observed_at: DateTime.utc_now(),
         sessions: %{
           data: Enum.map(body["data"] || [], &anthropic_session/1),
           next_page: body["next_page"]
         }
       }}
    end
  end

  defp api_key(opts, provider) do
    case Keyword.get(opts, :api_key) || Config.get([provider, :api_key]) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _other -> {:error, :missing_api_key}
    end
  end

  defp get(url, headers, params) do
    {request_fun, params} = Keyword.pop!(params, :request_fun)
    params = Enum.reject(params, fn {_key, value} -> is_nil(value) end)

    case request_fun.(url: url, headers: headers, params: params, receive_timeout: 30_000) do
      {:ok, %{status: status, body: %{} = body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        error = if is_map(body), do: body["error"], else: nil
        message = if is_map(error), do: error["message"], else: nil
        {:error, %{status: status, message: message}}

      {:error, _error} ->
        {:error, :transport_error}
    end
  end

  defp page(body, mapper) do
    data = body["data"] || []

    last_id =
      case List.last(data) do
        %{"id" => id} -> id
        _other -> nil
      end

    %{
      data: Enum.map(data, mapper),
      has_more: body["has_more"] == true,
      next_after: if(body["has_more"] == true, do: last_id)
    }
  end

  defp openai_container(row) do
    %{
      id: row["id"],
      memory_limit: row["memory_limit"],
      created_at: row["created_at"],
      last_active_at: row["last_active_at"],
      status: row["status"]
    }
  end

  defp openai_vector_store(row) do
    %{id: row["id"], usage_bytes: row["usage_bytes"], created_at: row["created_at"], status: row["status"]}
  end

  defp google_cache(row) do
    usage = row["usageMetadata"] || %{}

    %{
      name: row["name"],
      model: row["model"],
      create_time: row["createTime"],
      expire_time: row["expireTime"],
      total_token_count: usage["totalTokenCount"]
    }
  end

  defp anthropic_session(row) do
    usage = row["usage"] || %{}
    cost = usage["list_cost"] || %{}

    %{
      id: row["id"],
      status: row["status"],
      updated_at: row["updated_at"],
      active_seconds: usage["active_seconds"],
      list_cost_cents: cost["amount"],
      currency: cost["currency"]
    }
  end
end
