defmodule BeamWeaver.Core.LLM do
  @moduledoc """
  Behaviour for text completion model providers.
  """

  alias BeamWeaver.Core.Error

  @callback complete(term(), String.t(), keyword()) ::
              {:ok, String.t()} | {:error, Error.t() | term()}

  @doc """
  Completes a text prompt and validates the response shape.
  """
  @spec complete(term(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, Error.t() | term()}
  def complete(model, prompt, opts \\ [])

  def complete(model, prompt, opts) when is_binary(prompt) do
    case model.__struct__.complete(model, prompt, opts) do
      {:ok, completion} when is_binary(completion) ->
        {:ok, completion}

      {:error, _error} = error ->
        error

      other ->
        {:error,
         Error.new(:invalid_response, "LLM returned an invalid response", %{
           response: inspect(other)
         })}
    end
  end

  def complete(_model, _prompt, _opts),
    do: {:error, Error.new(:invalid_prompt, "prompt must be a string")}

  @doc """
  Alias for `complete/3`.

  Uses the same `invoke` name as other BeamWeaver runnables and models, which
  keeps composition code uniform.
  """
  @spec invoke(term(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, Error.t() | term()}
  def invoke(model, prompt, opts \\ []), do: complete(model, prompt, opts)

  @doc """
  Streams text completion chunks.

  Returns `{:ok, enumerable}` of string chunks. Providers can implement
  `stream/3` for native streaming. Providers that only implement `complete/3`
  are exposed as a one-chunk stream.
  """
  @spec stream(term(), String.t(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t() | term()}
  def stream(model, prompt, opts \\ [])

  def stream(model, prompt, opts) when is_binary(prompt) do
    result =
      if BeamWeaver.Behaviour.exported?(model.__struct__, :stream, 3) do
        model.__struct__.stream(model, prompt, opts)
      else
        with {:ok, completion} <- complete(model, prompt, opts), do: {:ok, [completion]}
      end

    case result do
      {:ok, chunks} ->
        validate_chunks(chunks)

      {:error, _error} = error ->
        error

      other ->
        {:error,
         Error.new(:invalid_response, "LLM returned an invalid stream response", %{
           response: inspect(other)
         })}
    end
  end

  def stream(_model, _prompt, _opts),
    do: {:error, Error.new(:invalid_prompt, "prompt must be a string")}

  @doc """
  Completes each prompt and returns ordered tagged results.
  """
  @spec batch(term(), [String.t()], keyword()) :: [
          {:ok, String.t()} | {:error, Error.t() | term()}
        ]
  def batch(model, prompts, opts \\ []) when is_list(prompts) do
    Enum.map(prompts, &complete(model, &1, opts))
  end

  defp validate_chunks(chunks) when is_list(chunks) do
    if Enum.all?(chunks, &is_binary/1) do
      {:ok, chunks}
    else
      {:error,
       Error.new(:invalid_response, "LLM stream chunks must be strings", %{
         response: inspect(chunks)
       })}
    end
  end

  defp validate_chunks(chunks) do
    if Enumerable.impl_for(chunks) do
      {:ok, chunks}
    else
      {:error,
       Error.new(:invalid_response, "LLM stream response must be enumerable", %{
         response: inspect(chunks)
       })}
    end
  end
end
