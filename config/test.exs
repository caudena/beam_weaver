import Config

postgres_url = System.get_env("BEAM_WEAVER_POSTGRES_URL")

config :beam_weaver,
       :test,
       Keyword.merge(
         Application.get_env(:beam_weaver, :test, []),
         postgres_url: postgres_url
       )
