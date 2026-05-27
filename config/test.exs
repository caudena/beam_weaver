import Config

postgres_url = System.get_env("BEAM_WEAVER_POSTGRES_URL")
docker_image = System.get_env("BEAM_WEAVER_DOCKER_TEST_IMAGE")

config :beam_weaver,
       :test,
       Keyword.merge(
         Application.get_env(:beam_weaver, :test, []),
         postgres_url: postgres_url,
         docker_image: docker_image
       )
