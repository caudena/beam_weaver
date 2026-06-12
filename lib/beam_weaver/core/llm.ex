defmodule BeamWeaver.Core.LLM do
  @moduledoc """
  Behaviour for text completion model providers.
  """

  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Prompt
  alias BeamWeaver.Result

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
  LangChain-compatible naming for a single text completion.

  BeamWeaver keeps `complete/3` as the canonical native name, while `invoke/3`
  makes runnable/model composition ergonomic.
  """
  @spec invoke(term(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, Error.t() | term()}
  def invoke(model, prompt, opts \\ []), do: complete(model, prompt, opts)

  @doc """
  Streams text completion chunks.

  Providers can implement `stream/3` for native streaming. Providers that only
  implement `complete/3` are exposed as a one-chunk stream, matching the
  BeamWeaver convention that streams are lazy-ish enumerables over native values
  rather than Python async generators.
  """
  @spec stream(term(), String.t(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t() | term()}
  def stream(model, prompt, opts \\ [])

  def stream(model, prompt, opts) when is_binary(prompt) do
    result =
      if function_exported_loaded?(model.__struct__, :stream, 3) do
        model.__struct__.stream(model, prompt, opts)
      else
        case complete(model, prompt, opts) do
          {:ok, completion} -> {:ok, [completion]}
          {:error, _error} = error -> error
        end
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

  @doc """
  Completes each prompt and returns either all completions or the first tagged
  error.
  """
  @spec generate(term(), [String.t()], keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def generate(model, prompts, opts \\ []) when is_list(prompts) do
    model
    |> batch(prompts, opts)
    |> Result.collect()
  end

  @doc """
  Completes prompt values after converting them through the Prompt protocol
  surface.
  """
  @spec generate_prompt(term(), [String.t() | term()], keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def generate_prompt(model, prompts, opts \\ []) when is_list(prompts) do
    prompts
    |> Enum.map(&prompt_to_string/1)
    |> then(&generate(model, &1, opts))
  end

  @doc """
  Starts async text completion.
  """
  @spec async_complete(term(), String.t(), keyword()) :: Async.handle()
  def async_complete(model, prompt, opts \\ []) do
    Async.run_call(opts, &complete(model, prompt, &1))
  end

  @doc """
  Starts async text-completion streaming.
  """
  @spec async_stream(term(), String.t(), keyword()) :: Async.handle()
  def async_stream(model, prompt, opts \\ []) do
    Async.run_call(opts, &stream(model, prompt, &1))
  end

  @doc """
  Starts an ordered async batch of text completions.
  """
  @spec async_batch(term(), [String.t()], keyword()) :: [Async.handle()]
  def async_batch(model, prompts, opts \\ []) when is_list(prompts) do
    Async.batch_call(prompts, opts, &complete(model, &1, &2))
  end

  @doc """
  Starts async text generation for a prompt list.
  """
  @spec async_generate(term(), [String.t()], keyword()) :: Async.handle()
  def async_generate(model, prompts, opts \\ []) do
    Async.run_call(opts, &generate(model, prompts, &1))
  end

  @doc """
  Starts async text generation for prompt values.
  """
  @spec async_generate_prompt(term(), [String.t() | term()], keyword()) :: Async.handle()
  def async_generate_prompt(model, prompts, opts \\ []) do
    Async.run_call(opts, &generate_prompt(model, prompts, &1))
  end

  defp prompt_to_string(%Prompt.Value{} = value), do: Prompt.to_string(value)
  defp prompt_to_string(prompt) when is_binary(prompt), do: prompt
  defp prompt_to_string(prompt), do: to_string(prompt)

  defp function_exported_loaded?(module, function, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end

  defp validate_chunks(chunks) do
    cond do
      is_list(chunks) ->
        validate_chunk_list(chunks)

      Enumerable.impl_for(chunks) ->
        {:ok, chunks}

      true ->
        {:error,
         Error.new(:invalid_response, "LLM stream response must be enumerable", %{
           response: inspect(chunks)
         })}
    end
  end

  defp validate_chunk_list(chunks) do
    if Enum.all?(chunks, &is_binary/1) do
      {:ok, chunks}
    else
      {:error,
       Error.new(:invalid_response, "LLM stream chunks must be strings", %{
         response: inspect(chunks)
       })}
    end
  end
end
