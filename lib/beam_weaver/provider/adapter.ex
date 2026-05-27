defmodule BeamWeaver.Provider.Adapter do
  @moduledoc """
  Behaviour for provider packages that plug into BeamWeaver's model registry.

  Provider adapters describe how a provider is identified, which model structs
  construct its chat or embedding clients, and which checked-in model profiles
  belong to it. External packages can implement this behaviour and register the
  module through `BeamWeaver.Provider.Registry.register/2`.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Models.Profile

  @callback provider() :: atom()
  @callback profiles() :: [Profile.t()]
  @callback chat_model(keyword()) :: {:ok, module()} | {:error, Error.t()}
  @callback embedding_model(keyword()) :: {:ok, module()} | {:error, Error.t()}
  @callback profile(String.t()) :: {:ok, Profile.t()} | {:error, Error.t()}
  @callback infer_provider?(String.t(), atom()) :: boolean()
  @callback default_model(atom()) :: String.t() | nil
  @callback capabilities() :: map()

  @optional_callbacks profiles: 0,
                      chat_model: 1,
                      embedding_model: 1,
                      profile: 1,
                      infer_provider?: 2,
                      default_model: 1,
                      capabilities: 0
end
