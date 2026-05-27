defmodule BeamWeaver.DocumentLoader.LangSmith do
  @moduledoc """
  Lazy LangSmith dataset-example loader.

  The loader keeps LangSmith at a transport/client boundary. Tests and
  applications can pass an injected client with `list_examples/2`; otherwise a
  small HTTP client uses BeamWeaver's transport behaviour.
  """

  alias BeamWeaver.Config
  alias BeamWeaver.Core.Document
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Provider.Options, as: ProviderOptions
  alias BeamWeaver.Transport
  alias BeamWeaver.Transport.Request
  alias BeamWeaver.Transport.Response

  defstruct opts: []

  @string_metadata_keys [:dataset_id, :created_at, :modified_at, :source_run_id, :id]
  @query_keys [
    :dataset_id,
    :dataset_name,
    :example_ids,
    :as_of,
    :splits,
    :inline_s3_urls,
    :offset,
    :limit,
    :metadata,
    :filter
  ]

  def load(%__MODULE__{opts: loader_opts}, load_opts) do
    opts = Keyword.merge(loader_opts, load_opts)
    client = Keyword.get(opts, :client) || __MODULE__.HTTPClient.new(opts)
    query = query(opts)

    with {:ok, examples} <- list_examples(client, query) do
      {:ok, Stream.map(examples, &document_from_example(&1, opts))}
    end
  rescue
    exception -> {:error, Error.new(:document_loader_error, Exception.message(exception))}
  end

  defp query(opts) do
    opts =
      opts
      |> Keyword.put_new(:inline_s3_urls, true)
      |> Keyword.put_new(:offset, 0)

    @query_keys
    |> Enum.flat_map(fn key ->
      case Keyword.fetch(opts, key) do
        {:ok, nil} -> []
        {:ok, value} -> [{key, value}]
        :error -> []
      end
    end)
    |> Map.new()
  end

  defp list_examples(client, query) when is_function(client, 1),
    do: normalize_examples(client.(query))

  defp list_examples({module, function}, query)
       when is_atom(module) and is_atom(function),
       do: normalize_examples(apply(module, function, [query]))

  defp list_examples(module, query) when is_atom(module) do
    cond do
      function_exported?(module, :list_examples, 1) ->
        normalize_examples(module.list_examples(query))

      function_exported?(module, :list_examples, 2) ->
        normalize_examples(module.list_examples(module, query))

      true ->
        unsupported_client(module)
    end
  end

  defp list_examples(%{__struct__: module} = client, query) do
    if function_exported?(module, :list_examples, 2) do
      normalize_examples(module.list_examples(client, query))
    else
      unsupported_client(module)
    end
  end

  defp list_examples(_client, _query), do: unsupported_client(nil)

  defp normalize_examples({:ok, examples}), do: {:ok, examples}
  defp normalize_examples({:error, %Error{} = error}), do: {:error, error}
  defp normalize_examples(examples) when is_list(examples), do: {:ok, examples}
  defp normalize_examples(%Stream{} = examples), do: {:ok, examples}

  defp normalize_examples(examples) do
    if Enumerable.impl_for(examples) do
      {:ok, examples}
    else
      {:error,
       Error.new(:document_loader_error, "LangSmith client returned non-enumerable examples", %{
         value: inspect(examples)
       })}
    end
  end

  defp unsupported_client(module) do
    {:error,
     Error.new(:document_loader_error, "LangSmith loader client must expose list_examples", %{
       client: inspect(module)
     })}
  end

  defp document_from_example(example, opts) do
    metadata = metadata_from_example(example)
    inputs = get_example_value(example, :inputs) || %{}

    content =
      opts
      |> Keyword.get(:content_key, "")
      |> content_path()
      |> Enum.reduce(inputs, &fetch_nested!/2)

    Document.new!(format_content(content, Keyword.get(opts, :format_content)),
      metadata: metadata
    )
  end

  defp metadata_from_example(example) do
    example
    |> public_map()
    |> stringify_metadata_values()
  end

  defp public_map(%{__struct__: _module} = struct), do: Map.from_struct(struct)
  defp public_map(map) when is_map(map), do: map

  defp stringify_metadata_values(metadata) do
    Enum.reduce(@string_metadata_keys, metadata, fn key, acc ->
      acc
      |> update_existing(key, &stringify_metadata_value/1)
      |> update_existing(to_string(key), &stringify_metadata_value/1)
    end)
  end

  defp update_existing(map, key, fun) do
    if Map.has_key?(map, key), do: Map.update!(map, key, fun), else: map
  end

  defp stringify_metadata_value(nil), do: nil
  defp stringify_metadata_value(value) when is_binary(value), do: value
  defp stringify_metadata_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp stringify_metadata_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp stringify_metadata_value(%Date{} = value), do: Date.to_iso8601(value)
  defp stringify_metadata_value(%Time{} = value), do: Time.to_iso8601(value)
  defp stringify_metadata_value(value), do: to_string(value)

  defp get_example_value(example, field) when is_map(example) do
    string_field = to_string(field)

    case {Map.fetch(example, field), Map.fetch(example, string_field)} do
      {{:ok, value}, _string_value} -> value
      {:error, {:ok, value}} -> value
      {:error, :error} -> nil
    end
  end

  defp content_path(nil), do: []
  defp content_path(""), do: []

  defp content_path(path) when is_binary(path),
    do: String.split(path, ".", trim: true)

  defp content_path(path) when is_list(path), do: path
  defp content_path(path), do: [path]

  defp fetch_nested!(field, value) when is_map(value) do
    cond do
      Map.has_key?(value, field) ->
        Map.fetch!(value, field)

      is_atom(field) and Map.has_key?(value, Atom.to_string(field)) ->
        Map.fetch!(value, Atom.to_string(field))

      is_binary(field) ->
        value
        |> Map.keys()
        |> Enum.find(&(to_string(&1) == field))
        |> case do
          nil -> raise KeyError, key: field, term: value
          key -> Map.fetch!(value, key)
        end

      true ->
        raise KeyError, key: field, term: value
    end
  end

  defp fetch_nested!(field, value), do: raise(KeyError, key: field, term: value)

  defp format_content(content, formatter) when is_function(formatter, 1),
    do: formatter.(content)

  defp format_content(content, _formatter) when is_binary(content), do: content

  defp format_content(content, _formatter) do
    BeamWeaver.JSON.encode!(content, pretty: true)
  rescue
    _exception -> to_string(content)
  end

  defmodule HTTPClient do
    @moduledoc false

    defstruct endpoint: "https://api.smith.langchain.com",
              api_key: nil,
              transport: nil,
              transport_opts: [],
              timeout: 15_000

    def new(opts) do
      %__MODULE__{
        endpoint:
          Config.option(
            opts,
            :endpoint,
            [:langsmith, :endpoint],
            "https://api.smith.langchain.com"
          ),
        api_key: Config.option(opts, :api_key, [:langsmith, :api_key]),
        transport: ProviderOptions.default_transport(opts[:transport]),
        transport_opts: opts[:transport_opts] || [],
        timeout: opts[:timeout] || 15_000
      }
    end

    def list_examples(%__MODULE__{} = client, query) do
      request =
        Request.new(
          method: :get,
          url: examples_url(client.endpoint, query),
          headers: headers(client),
          options: [timeout: client.timeout]
        )

      with {:ok, %Response{} = response} <-
             Transport.request(client.transport, request, client.transport_opts),
           :ok <- check_status(response),
           {:ok, body} <- decode_body(response.body) do
        examples_from_body(body)
      end
    end

    defp examples_url(endpoint, query) do
      base = endpoint |> String.trim_trailing("/") |> Kernel.<>("/examples")
      encoded = URI.encode_query(flatten_query(query))
      if encoded == "", do: base, else: base <> "?" <> encoded
    end

    defp flatten_query(query) do
      Enum.flat_map(query, fn
        {_key, nil} ->
          []

        {key, values} when is_list(values) ->
          Enum.map(values, &{to_string(key), encode_query_value(&1)})

        {key, value} ->
          [{to_string(key), encode_query_value(value)}]
      end)
    end

    defp encode_query_value(value) when is_binary(value), do: value
    defp encode_query_value(value) when is_atom(value), do: Atom.to_string(value)
    defp encode_query_value(value) when is_number(value) or is_boolean(value), do: value

    defp encode_query_value(value) do
      BeamWeaver.JSON.encode!(value)
    rescue
      _exception -> to_string(value)
    end

    defp headers(%__MODULE__{api_key: nil}), do: [{"accept", "application/json"}]
    defp headers(%__MODULE__{api_key: ""}), do: [{"accept", "application/json"}]

    defp headers(%__MODULE__{api_key: api_key}) do
      [{"accept", "application/json"}, {"x-api-key", api_key}]
    end

    defp check_status(%Response{status: status}) when status in 200..299, do: :ok

    defp check_status(%Response{status: status}) do
      {:error,
       Error.new(:document_loader_http_error, "LangSmith loader received non-success status", %{
         status: status
       })}
    end

    defp decode_body(body) when is_binary(body), do: BeamWeaver.JSON.decode(body)
    defp decode_body(body), do: {:ok, body}

    defp examples_from_body(examples) when is_list(examples), do: {:ok, examples}

    defp examples_from_body(%{"examples" => examples}) when is_list(examples), do: {:ok, examples}
    defp examples_from_body(%{"data" => examples}) when is_list(examples), do: {:ok, examples}

    defp examples_from_body(body) do
      {:error,
       Error.new(:document_loader_error, "LangSmith response did not include examples", %{
         body: inspect(body)
       })}
    end
  end
end
