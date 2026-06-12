defmodule BeamWeaver.Models.FakeLLM do
  @moduledoc false

  @behaviour BeamWeaver.Core.LLM

  alias BeamWeaver.Core.LanguageModel
  alias BeamWeaver.Models.ParamPolicy

  defstruct id: nil,
            responses: nil,
            response: "",
            parent: nil,
            profile: nil,
            tokenizer: nil,
            stream_chunks: nil,
            param_policy: nil,
            error: nil

  def new(opts \\ []) do
    opts
    |> Map.new()
    |> Map.put_new(:id, make_ref())
    |> then(&struct(__MODULE__, &1))
  end

  @impl true
  def complete(%__MODULE__{} = model, prompt, opts) do
    with :ok <-
           ParamPolicy.validate(
             model.profile,
             opts,
             Keyword.get(opts, :param_policy, model.param_policy)
           ) do
      if model.parent, do: send(model.parent, {:fake_llm_call, prompt, opts})

      if model.error do
        {:error, model.error}
      else
        {:ok, next_response(model)}
      end
    end
  end

  def stream(%__MODULE__{stream_chunks: chunks}, _prompt, _opts) when is_list(chunks),
    do: {:ok, chunks}

  def stream(%__MODULE__{responses: responses} = model, prompt, opts)
      when is_list(responses) and responses != [] do
    with {:ok, response} <- complete(model, prompt, opts) do
      {:ok, String.graphemes(response)}
    end
  end

  def stream(%__MODULE__{} = model, prompt, opts) do
    with {:ok, response} <- complete(model, prompt, opts), do: {:ok, [response]}
  end

  def count_tokens(%__MODULE__{tokenizer: nil}, input, _opts),
    do: {:ok, LanguageModel.count_tokens_approximately(input)}

  def count_tokens(%__MODULE__{tokenizer: tokenizer}, input, opts),
    do: LanguageModel.count_tokens({:tokenizer, tokenizer}, input, opts)

  defp next_response(%__MODULE__{responses: responses} = model)
       when is_list(responses) and responses != [] do
    key = {:beam_weaver_fake_llm_response_index, model.id || :erlang.phash2(responses)}
    index = Process.get(key, 0)
    Process.put(key, rem(index + 1, length(responses)))
    Enum.at(responses, index)
  end

  defp next_response(%__MODULE__{response: response}), do: response
end
