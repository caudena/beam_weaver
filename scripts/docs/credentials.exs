defmodule BeamWeaver.Docs.Credentials do
  @moduledoc false
  @keys [
    openai: ~w(OPENAI_API_KEY),
    google: ~w(GOOGLE_API_KEY GEMINI_API_KEY),
    anthropic: ~w(ANTHROPIC_API_KEY),
    xai: ~w(XAI_API_KEY),
    deepseek: ~w(DEEPSEEK_API_KEY),
    moonshot: ~w(MOONSHOT_API_KEY KIMI_API_KEY),
    zai: ~w(ZAI_API_KEY),
    typesafe: ~w(TYPESAFE_API_KEY TYPESAFE_API)
  ]

  def keys, do: @keys

  def configure_live_providers! do
    load_dotenv(Path.join(Path.expand("../..", __DIR__), ".env"))

    for {provider, names} <- @keys, key = Enum.find_value(names, &non_blank_env/1) do
      Application.put_env(
        :beam_weaver,
        provider,
        Keyword.put(Application.get_env(:beam_weaver, provider, []), :api_key, key)
      )
    end

    :ok
  end

  defp load_dotenv(path) do
    if File.exists?(path) do
      for line <- File.stream!(path),
          [_, name, value] <- [Regex.run(~r/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/, line)],
          name in Enum.flat_map(@keys, &elem(&1, 1)),
          System.get_env(name) in [nil, ""],
          do: System.put_env(name, String.trim(value, ~s(")) |> String.trim("'"))
    end
  end

  defp non_blank_env(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _missing -> nil
    end
  end

  def missing_credentials(providers) do
    for provider <- providers,
        key = String.to_existing_atom(to_string(provider)),
        not Enum.any?(Keyword.fetch!(@keys, key), &non_blank_env/1),
        do: to_string(provider)
  end
end
