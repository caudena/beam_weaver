defmodule BeamWeaver.Provider.Adapter do
  @moduledoc """
  Behaviour for provider packages that plug into BeamWeaver's model registry.

  Provider adapters describe how a provider is identified, which model structs
  construct its chat, embedding, or decision clients, and which checked-in model profiles
  belong to it. External packages can implement this behaviour and register the
  module through `BeamWeaver.Provider.Registry.register/2`.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Models.Profile

  @doc """
  Returns the stable atom prefix registered for this adapter.
  """
  @callback provider() :: atom()
  @doc """
  Returns checked-in capability profiles, not account-specific live availability.
  """
  @callback profiles() :: [Profile.t()]
  @doc """
  Resolves the chat implementation module for the supplied options when supported.
  """
  @callback chat_model(keyword()) :: {:ok, module()} | {:error, Error.t()}
  @doc """
  Resolves the typed-decision implementation module when supported.
  """
  @callback decision_model(keyword()) :: {:ok, module()} | {:error, Error.t()}
  @doc """
  Resolves the embedding implementation module when supported.
  """
  @callback embedding_model(keyword()) :: {:ok, module()} | {:error, Error.t()}
  @doc """
  Returns local compatibility data for a native model identifier.
  """
  @callback profile(String.t()) :: {:ok, Profile.t()} | {:error, Error.t()}
  @doc """
  Determines whether an unprefixed identifier belongs to this provider and operation kind.
  """
  @callback infer_provider?(String.t(), atom()) :: boolean()
  @doc """
  Returns the default native identifier for an operation kind, or nil.
  """
  @callback default_model(atom()) :: String.t() | nil
  @doc """
  Returns provider-advertised operation metadata; models can have narrower capabilities.
  """
  @callback capabilities() :: map()

  @optional_callbacks profiles: 0,
                      chat_model: 1,
                      embedding_model: 1,
                      decision_model: 1,
                      profile: 1,
                      infer_provider?: 2,
                      default_model: 1,
                      capabilities: 0
end
