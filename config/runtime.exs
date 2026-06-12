import Config

if config_env() != :test do
  non_blank = fn name ->
    case System.get_env(name) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _missing ->
        nil
    end
  end

  first_env = fn names ->
    names
    |> List.wrap()
    |> Enum.find_value(non_blank)
  end

  bool_env = fn name ->
    case non_blank.(name) do
      nil -> nil
      value -> String.downcase(value) in ["1", "true", "yes", "on"]
    end
  end

  compact = fn values ->
    values
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  config :beam_weaver,
         :openai,
         Keyword.merge(
           Application.get_env(:beam_weaver, :openai, []),
           compact.(
             api_key: non_blank.("OPENAI_API_KEY"),
             organization: first_env.(["OPENAI_ORG_ID", "OPENAI_ORGANIZATION"]),
             project: first_env.(["OPENAI_PROJECT_ID", "OPENAI_PROJECT"])
           )
         )

  config :beam_weaver,
         :anthropic,
         Keyword.merge(
           Application.get_env(:beam_weaver, :anthropic, []),
           compact.(api_key: non_blank.("ANTHROPIC_API_KEY"))
         )

  google_api_key = first_env.(["GOOGLE_API_KEY", "GEMINI_API_KEY"])

  config :beam_weaver,
         :google,
         Keyword.merge(
           Application.get_env(:beam_weaver, :google, []),
           compact.(
             api_key: google_api_key,
             base_url: first_env.(["GOOGLE_BASE_URL", "GOOGLE_API_URL"])
           )
         )

  config :beam_weaver,
         :xai,
         Keyword.merge(
           Application.get_env(:beam_weaver, :xai, []),
           compact.(
             api_key: non_blank.("XAI_API_KEY"),
             base_url: first_env.(["XAI_API_BASE", "XAI_BASE_URL", "XAI_API_URL"])
           )
         )

  config :beam_weaver,
         :moonshot,
         Keyword.merge(
           Application.get_env(:beam_weaver, :moonshot, []),
           compact.(
             api_key: non_blank.("MOONSHOT_API_KEY"),
             base_url: first_env.(["MOONSHOT_BASE_URL", "MOONSHOT_API_URL"])
           )
         )

  provider_api_keys =
    compact.(
      openai: non_blank.("OPENAI_API_KEY"),
      anthropic: non_blank.("ANTHROPIC_API_KEY"),
      google: google_api_key,
      xai: non_blank.("XAI_API_KEY"),
      moonshot: non_blank.("MOONSHOT_API_KEY")
    )

  sandbox_env = non_blank.("BEAM_WEAVER_DEEPAGENTS_SANDBOX")

  eval_overrides =
    compact.(
      deep_agents_harbor?: bool_env.("BEAM_WEAVER_DEEPAGENTS_HARBOR"),
      external_sandbox?: if(sandbox_env, do: sandbox_env in ["1", "true", "TRUE", "docker"], else: nil)
    )

  eval_overrides =
    if provider_api_keys == [] do
      eval_overrides
    else
      Keyword.put(eval_overrides, :provider_api_keys, provider_api_keys)
    end

  config :beam_weaver,
         :evals,
         Keyword.merge(
           Application.get_env(:beam_weaver, :evals, []),
           eval_overrides
         )

  config :beam_weaver,
         :examples,
         Keyword.merge(
           Application.get_env(:beam_weaver, :examples, []),
           compact.(
             deep_agents_live?: bool_env.("BEAM_WEAVER_DEEPAGENTS_EXAMPLES_LIVE"),
             deep_agents_model: non_blank.("BEAM_WEAVER_DEEPAGENTS_EXAMPLES_MODEL")
           )
         )
end
