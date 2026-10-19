defmodule BeamWeaver.Provider.Fake do
  @moduledoc false

  @behaviour BeamWeaver.Provider.Adapter

  alias BeamWeaver.Models.ProfileRegistry

  @impl true
  def provider, do: :fake

  @impl true
  def profiles, do: ProfileRegistry.profiles(:fake)

  @impl true
  def chat_model(_opts), do: {:ok, BeamWeaver.Models.FakeChatModel}

  @impl true
  def embedding_model(_opts), do: {:ok, BeamWeaver.Models.FakeEmbeddingModel}

  @impl true
  def infer_provider?("chat", :chat), do: true
  def infer_provider?("embedding", :embedding), do: true
  def infer_provider?(_model, _kind), do: false
end
