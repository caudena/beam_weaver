defmodule BeamWeaver.BlobLoader do
  @moduledoc """
  Behaviour and facade for lazy blob loading.
  """

  alias BeamWeaver.Blob
  alias BeamWeaver.Core.Error

  @callback load(term(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}

  @spec load(term(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def load(loader, opts \\ []) do
    loader.__struct__.load(loader, opts)
  rescue
    exception -> {:error, Error.new(:blob_loader_error, Exception.message(exception))}
  end

  def yield_blobs(loader, opts \\ []), do: load(loader, opts)

  def data(values, opts \\ []) do
    struct(BeamWeaver.BlobLoader.Data, values: List.wrap(values), opts: opts)
  end

  def paths(paths, opts \\ []) do
    struct(BeamWeaver.BlobLoader.Path, paths: List.wrap(paths), opts: opts)
  end

  def urls(urls, opts \\ []) do
    struct(BeamWeaver.BlobLoader.URL, urls: List.wrap(urls), opts: opts)
  end

  def url(urls, opts \\ []), do: urls(urls, opts)

  defmodule Data do
    @moduledoc false
    @behaviour BeamWeaver.BlobLoader

    alias BeamWeaver.BlobLike

    defstruct values: [], opts: []

    @impl true
    def load(%__MODULE__{values: values}, _opts) do
      {:ok,
       Stream.map(values, fn value ->
         case BlobLike.to_blob(value) do
           {:ok, blob} -> blob
           {:error, error} -> raise RuntimeError, message: error.message
         end
       end)}
    end
  end

  defmodule Path do
    @moduledoc false
    @behaviour BeamWeaver.BlobLoader

    defstruct paths: [], opts: []

    @impl true
    def load(%__MODULE__{paths: paths, opts: opts}, _load_opts) do
      {:ok,
       Stream.map(paths, fn path ->
         case Blob.from_path(path, opts) do
           {:ok, blob} -> blob
           {:error, error} -> raise RuntimeError, message: error.message
         end
       end)}
    end
  end

  defmodule URL do
    @moduledoc false
    @behaviour BeamWeaver.BlobLoader

    alias BeamWeaver.Blob
    alias BeamWeaver.Core.Error
    alias BeamWeaver.Provider.Options, as: ProviderOptions
    alias BeamWeaver.Transport
    alias BeamWeaver.Transport.Request
    alias BeamWeaver.Transport.Response
    alias BeamWeaver.Transport.URLPolicy

    defstruct urls: [], opts: []

    @impl true
    def load(%__MODULE__{urls: urls, opts: loader_opts}, load_opts) do
      opts = Keyword.merge(loader_opts, load_opts)
      policy = URLPolicy.new(Keyword.get(opts, :url_policy, opts))

      with {:ok, urls} <- validate_urls(urls, policy) do
        {:ok,
         Stream.map(urls, fn url ->
           case fetch(url, policy, opts) do
             {:ok, blob} -> blob
             {:error, error} -> raise RuntimeError, message: error.message
           end
         end)}
      end
    end

    defp validate_urls(urls, policy) do
      Enum.reduce_while(urls, {:ok, []}, fn url, {:ok, acc} ->
        case URLPolicy.validate(url, policy) do
          {:ok, safe_url} -> {:cont, {:ok, [safe_url | acc]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
      |> case do
        {:ok, safe_urls} -> {:ok, Enum.reverse(safe_urls)}
        other -> other
      end
    end

    defp fetch(url, policy, opts) do
      transport = ProviderOptions.default_transport(Keyword.get(opts, :transport))
      transport_opts = Keyword.get(opts, :transport_opts, [])

      request =
        Request.new(
          method: :get,
          url: url,
          headers: Keyword.get(opts, :headers, []),
          options: [timeout: policy.timeout]
        )

      with {:ok, %Response{} = response} <- Transport.request(transport, request, transport_opts),
           :ok <- check_status(response),
           {:ok, body} <- response_body(response),
           :ok <- check_size(body, policy) do
        Blob.from_data(body,
          source: url,
          metadata:
            %{source: url, status: response.status, headers: response.headers}
            |> Map.merge(Keyword.get(opts, :metadata, %{}))
        )
      else
        {:error, %Error{} = error} -> {:error, error}
        {:error, error} -> {:error, Error.new(:blob_loader_error, inspect(error))}
      end
    end

    defp check_status(%Response{status: status}) when status in 200..299, do: :ok

    defp check_status(%Response{} = response) do
      {:error,
       Error.new(:blob_loader_http_error, "URL loader received non-success status", %{
         status: response.status
       })}
    end

    defp response_body(%Response{body: body}) when is_binary(body), do: {:ok, body}

    defp response_body(%Response{body: body}) do
      case BeamWeaver.JSON.encode(body) do
        {:ok, encoded} -> {:ok, encoded}
        {:error, error} -> {:error, Error.new(:blob_loader_error, Exception.message(error))}
      end
    end

    defp check_size(body, policy) do
      if byte_size(body) <= policy.max_bytes do
        :ok
      else
        {:error,
         Error.new(:blob_too_large, "URL loader response exceeded max_bytes", %{
           size: byte_size(body),
           max_bytes: policy.max_bytes
         })}
      end
    end
  end
end
