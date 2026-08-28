defmodule BeamWeaver.OpenAI.CodexResponses do
  @moduledoc """
  Pure request-contract helpers for Codex-flavoured Responses endpoints.

  Authentication lifecycle and endpoint admission intentionally remain the
  responsibility of the embedding application. This module only owns the
  reusable wire shape: first-party compatibility headers, `store: false`,
  encrypted reasoning replay, and bounded request bodies.
  """

  @default_maximum_body_bytes 8_388_608
  @default_user_agent "codex_cli_rs/beam_weaver"
  @unsupported_parameters ["max_output_tokens", "max_tool_calls"]

  @spec headers(String.t(), keyword()) :: [{String.t(), String.t()}]
  def headers(access_token, opts \\ []) when is_binary(access_token) do
    user_agent = Keyword.get(opts, :user_agent, @default_user_agent)

    [
      {"originator", "codex_cli_rs"},
      {"user-agent", normalize_user_agent(user_agent)}
    ]
    |> maybe_put_account_header(account_id(access_token))
  end

  @spec request_options(keyword()) :: keyword()
  def request_options(opts \\ []) do
    opts
    |> Keyword.drop([:max_output_tokens, :max_tool_calls])
    |> Keyword.put(:store, false)
    |> Keyword.put_new(:stream, true)
    |> Keyword.put_new(:tool_choice, "auto")
    |> Keyword.put_new(:parallel_tool_calls, true)
    |> Keyword.put_new(:include, ["reasoning.encrypted_content"])
    |> Keyword.put_new(:reasoning, %{effort: "medium", summary: "auto"})
  end

  @spec normalize_body(map(), keyword()) :: {:ok, map()} | {:error, atom()}
  def normalize_body(body, opts \\ []) when is_map(body) do
    maximum = Keyword.get(opts, :maximum_body_bytes, @default_maximum_body_bytes)

    if is_integer(maximum) and maximum > 0 do
      normalized =
        body
        |> normalize_optional_key(:include, "include")
        |> normalize_optional_key(:tools, "tools")
        |> Map.drop([:store, :max_output_tokens, :max_tool_calls] ++ @unsupported_parameters)
        |> Map.put("store", false)
        |> Map.put_new("include", ["reasoning.encrypted_content"])
        |> drop_empty_tools()

      case BeamWeaver.JSON.encode(normalized) do
        {:ok, encoded} when byte_size(encoded) <= maximum -> {:ok, normalized}
        {:ok, _encoded} -> {:error, :codex_request_too_large}
        {:error, _reason} -> {:error, :invalid_codex_request}
      end
    else
      {:error, :invalid_codex_request}
    end
  end

  @spec account_id(String.t()) :: String.t() | nil
  def account_id(access_token) when is_binary(access_token) do
    with [_header, payload, _signature | _rest] <- String.split(access_token, "."),
         {:ok, decoded} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} <- Jason.decode(decoded),
         %{"https://api.openai.com/auth" => %{"chatgpt_account_id" => account_id}} <- claims,
         true <- is_binary(account_id) and account_id != "" do
      account_id
    else
      _reason -> nil
    end
  end

  defp normalize_user_agent("codex_cli_rs/" <> _rest = value), do: value
  defp normalize_user_agent(_value), do: @default_user_agent

  defp maybe_put_account_header(headers, nil), do: headers

  defp maybe_put_account_header(headers, account_id),
    do: [{"ChatGPT-Account-ID", account_id} | headers]

  defp drop_empty_tools(%{"tools" => []} = body), do: Map.delete(body, "tools")
  defp drop_empty_tools(body), do: body

  defp normalize_optional_key(body, atom_key, string_key) do
    cond do
      Map.has_key?(body, string_key) -> Map.delete(body, atom_key)
      Map.has_key?(body, atom_key) -> body |> Map.put(string_key, Map.fetch!(body, atom_key)) |> Map.delete(atom_key)
      true -> body
    end
  end
end
