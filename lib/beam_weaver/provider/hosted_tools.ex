defmodule BeamWeaver.Provider.HostedTools do
  @moduledoc """
  Provider-owned tool declarations for model requests.

  Defaults describe tools usable without user-supplied resources. Explicit
  declarations and profile `hosted_tools` metadata are opaque provider JSON:
  new tool types do not require a renderer or response allowlist here. Tools
  needing files, stores, servers or other resources are supplied with those
  bindings by the caller. Client-executed tools remain a separate contract.
  """

  alias BeamWeaver.Models.Profile
  alias BeamWeaver.Provider.Registry

  def defaults(provider, dialect, model) do
    extra =
      case Registry.profile(provider, model) do
        {:ok, %Profile{extra: extra}} -> extra
        _ -> %{}
      end

    case Map.get(extra, :hosted_tools, Map.get(extra, "hosted_tools")) do
      tools when is_list(tools) -> BeamWeaver.MapShape.normalize_value(tools)
      _ -> defaults_for(provider, dialect, model, extra)
    end
  end

  # The subscription endpoint exposes a different server tool contract from
  # the public Responses API. Provider discovery can supply additional types.
  defp defaults_for(:openai, :codex_responses, _model, _extra),
    do: [%{"type" => "web_search"}]

  defp defaults_for(:openai, :responses, model, _extra) do
    base = [
      %{"type" => "web_search"},
      %{"type" => "code_interpreter", "container" => %{"type" => "auto"}},
      %{"type" => "image_generation"}
    ]

    if String.starts_with?(model, ["gpt-6", "gpt-5.4", "gpt-5.5", "gpt-5.6"]),
      do: base ++ [%{"type" => "shell", "environment" => %{"type" => "container_auto"}}, %{"type" => "tool_search"}],
      else: base
  end

  defp defaults_for(:anthropic, :messages, _model, extra) do
    unsupported = Enum.map(Map.get(extra, :unsupported_server_tools, []), &to_string/1)

    [
      BeamWeaver.Anthropic.Tools.web_search(),
      BeamWeaver.Anthropic.Tools.web_fetch(),
      BeamWeaver.Anthropic.Tools.code_execution(),
      BeamWeaver.Anthropic.Tools.tool_search(name: "tool_search_tool_bm25")
    ]
    |> Enum.reject(&(&1["name"] in unsupported))
  end

  defp defaults_for(:google, :generate_content, _model, extra) do
    supported = Map.get(extra, :built_in_tools, [:google_search, :url_context, :code_execution, :google_maps])

    declarations = %{
      "google_search" => BeamWeaver.Google.Tools.google_search(),
      "url_context" => BeamWeaver.Google.Tools.url_context(),
      "code_execution" => BeamWeaver.Google.Tools.code_execution(),
      "google_maps" => BeamWeaver.Google.Tools.google_maps()
    }

    Enum.flat_map(supported, &List.wrap(Map.get(declarations, to_string(&1))))
  end

  defp defaults_for(:xai, :responses, _model, _extra),
    do: [%{"type" => "web_search"}, %{"type" => "x_search"}, %{"type" => "code_interpreter"}]

  defp defaults_for(:deepseek, :responses, _model, _extra), do: [%{"type" => "web_search"}]

  defp defaults_for(:zai, :chat_completions, _model, _extra),
    do: [%{"type" => "web_search", "web_search" => %{"enable" => true, "search_result" => true}}]

  defp defaults_for(:moonshot, :chat_completions, _model, extra) do
    if Map.get(extra, :web_search_supported) == true,
      do: [%{"type" => "builtin_function", "function" => %{"name" => "$web_search"}}],
      else: []
  end

  defp defaults_for(_provider, _dialect, _model, _extra), do: []

  @doc "Stable declaration identity; future provider types are retained."
  def identity(tool) when is_map(tool) do
    tool = BeamWeaver.MapShape.stringify_keys(tool)
    {tool["type"] || tool |> Map.keys() |> Enum.sort(), tool["name"] || tool["server_label"]}
  end

  def merge(defaults, configured) do
    replacements = Map.new(configured, &{identity(&1), &1})
    defaults = Enum.map(defaults, &Map.get(replacements, identity(&1), &1))
    Enum.uniq_by(defaults ++ configured, &identity/1)
  end
end
