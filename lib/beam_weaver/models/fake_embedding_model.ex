defmodule BeamWeaver.Models.FakeEmbeddingModel do
  @moduledoc false

  @behaviour BeamWeaver.Core.EmbeddingModel

  alias BeamWeaver.Models.ParamPolicy

  defstruct dimensions: 3,
            mode: :deterministic,
            profile: nil,
            tokenizer: nil,
            param_policy: nil,
            error: nil,
            parent: nil

  @impl true
  def embed_documents(%__MODULE__{} = model, documents, opts) do
    with :ok <- validate(model, opts) do
      if model.parent, do: send(model.parent, {:fake_embedding_documents, documents, opts})

      if model.error do
        {:error, model.error}
      else
        {:ok, Enum.map(documents, &vector(&1, model))}
      end
    end
  end

  @impl true
  def embed_query(%__MODULE__{} = model, query, opts) do
    with :ok <- validate(model, opts) do
      if model.parent, do: send(model.parent, {:fake_embedding_query, query, opts})

      if model.error do
        {:error, model.error}
      else
        {:ok, vector(query, model)}
      end
    end
  end

  defp validate(%__MODULE__{} = model, opts) do
    ParamPolicy.validate(
      model.profile,
      opts,
      Keyword.get(opts, :param_policy, model.param_policy)
    )
  end

  defp vector(_text, %__MODULE__{mode: :random, dimensions: dimensions}) do
    Enum.map(1..dimensions, fn _index -> :rand.uniform() * 2 - 1 end)
  end

  defp vector(text, %__MODULE__{dimensions: dimensions}) do
    base = :erlang.phash2(text, 1_000)
    Enum.map(1..dimensions, &((base + &1) / 1_000))
  end
end
