defmodule BeamWeaver.Graph.NodeSpec do
  @moduledoc false

  alias BeamWeaver.CachePolicy
  alias BeamWeaver.Core.Error
  alias BeamWeaver.ExecutionPolicy
  alias BeamWeaver.RetryPolicy
  alias BeamWeaver.TimeoutPolicy

  defstruct [
    :name,
    :fun,
    :kind,
    :input,
    :output,
    :deps,
    :condition,
    :input_schema,
    :output_schema,
    :execution_policy,
    :retry_policy,
    :error_handler,
    :cache_policy,
    destinations: [],
    metadata: %{},
    defer: false,
    retry: 0,
    timeout: :infinity,
    cache: false,
    triggers: []
  ]

  @type t :: %__MODULE__{}

  # The options `Graph.add_node/4` takes. Anything else is a mistake, such as
  # `retry_policy:` for `retry:`, that would otherwise be ignored silently.
  @options [
    :cache,
    :defer,
    :deps,
    :destinations,
    :error_handler,
    :input,
    :input_schema,
    :metadata,
    :output,
    :output_schema,
    :retry,
    :timeout,
    :triggers,
    :when
  ]

  @spec new(String.t(), term(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(name, callable, opts \\ []) do
    with :ok <- validate_options(name, opts),
         {:ok, node} <- BeamWeaver.Graph.IntoNode.to_node(callable, name, opts),
         {:ok, retry, retry_policy} <-
           normalize_retry(Keyword.get(opts, :retry, 0)),
         {:ok, timeout, execution_policy} <- normalize_timeout(Keyword.get(opts, :timeout, :infinity)),
         {:ok, cache, cache_policy} <- normalize_cache(Keyword.get(opts, :cache, false)) do
      {:ok,
       %__MODULE__{
         name: name,
         fun: Map.fetch!(node, :fun),
         kind: Map.fetch!(node, :kind),
         input: Keyword.get(opts, :input),
         output: Keyword.get(opts, :output),
         deps: normalize_deps(Keyword.get(opts, :deps, [])),
         condition: Keyword.get(opts, :when),
         input_schema: Keyword.get(opts, :input_schema, Map.get(node, :input_schema)),
         output_schema: Keyword.get(opts, :output_schema, Map.get(node, :output_schema)),
         destinations: normalize_destinations(Keyword.get(opts, :destinations, [])),
         metadata: normalize_metadata(Keyword.get(opts, :metadata, %{}), node),
         defer: Keyword.get(opts, :defer, false) == true,
         retry: retry,
         retry_policy: retry_policy,
         error_handler: Keyword.get(opts, :error_handler),
         timeout: timeout,
         execution_policy: execution_policy,
         cache: cache,
         cache_policy: cache_policy,
         triggers: Keyword.get(opts, :triggers, []) |> BeamWeaver.Graph.Execution.normalize_channels()
       }}
    end
  end

  defp validate_options(name, opts) do
    case opts |> Keyword.keys() |> Enum.uniq() |> Enum.reject(&(&1 in @options)) do
      [] ->
        :ok

      unknown ->
        {:error,
         Error.new(:invalid_node, "node #{name} has unknown options: #{Enum.map_join(unknown, ", ", &inspect/1)}", %{
           node: name,
           options: unknown,
           accepted: @options
         })}
    end
  end

  @spec new!(String.t(), term(), keyword()) :: t()
  def new!(name, callable, opts \\ []) do
    case new(name, callable, opts) do
      {:ok, spec} -> spec
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp normalize_retry(%RetryPolicy{} = policy) do
    with {:ok, policy} <- RetryPolicy.new(policy), do: {:ok, policy.max_attempts - 1, policy}
  end

  defp normalize_retry(opts) when is_list(opts) or is_map(opts) do
    with {:ok, policy} <- RetryPolicy.new(opts), do: {:ok, policy.max_attempts - 1, policy}
  end

  defp normalize_retry(retries) when is_integer(retries) and retries >= 0 do
    {:ok, retries, RetryPolicy.new!(max_attempts: retries + 1)}
  end

  defp normalize_retry(other) do
    {:error,
     Error.new(:invalid_graph, "invalid node retry policy", %{
       retry: inspect(other)
     })}
  end

  # A node's `timeout:`, and a `Send`'s: milliseconds, `:infinity`, a float
  # of seconds, `ExecutionPolicy` or `TimeoutPolicy` options or structs.
  # Without a time limit, the node runs until it finishes.
  @doc false
  @spec normalize_timeout(term()) :: {:ok, timeout() | nil, ExecutionPolicy.t()} | {:error, Error.t()}
  def normalize_timeout(%ExecutionPolicy{} = policy) do
    with {:ok, policy} <- ExecutionPolicy.new(policy), do: {:ok, policy.timeout, policy}
  end

  def normalize_timeout(%TimeoutPolicy{} = policy) do
    with {:ok, timeout} <- TimeoutPolicy.effective_timeout(policy) do
      {:ok, timeout || :infinity, ExecutionPolicy.new!(timeout: timeout || :infinity)}
    end
  end

  def normalize_timeout(timeout) when timeout in [nil, :infinity] do
    {:ok, :infinity, ExecutionPolicy.new!(timeout: :infinity)}
  end

  def normalize_timeout(timeout) when is_float(timeout) and timeout >= 0 do
    normalize_timeout(round(timeout * 1_000))
  end

  def normalize_timeout(timeout) when is_integer(timeout) and timeout >= 0 do
    {:ok, timeout, ExecutionPolicy.new!(timeout: timeout)}
  end

  def normalize_timeout(opts) when is_list(opts) do
    if timeout_policy_options?(opts) do
      normalize_timeout_policy(opts)
    else
      with {:ok, policy} <- ExecutionPolicy.new(opts), do: {:ok, policy.timeout, policy}
    end
  end

  def normalize_timeout(opts) when is_map(opts) do
    if timeout_policy_options?(opts) do
      normalize_timeout_policy(opts)
    else
      with {:ok, policy} <- ExecutionPolicy.new(opts), do: {:ok, policy.timeout, policy}
    end
  end

  def normalize_timeout(other) do
    {:error,
     Error.new(:invalid_graph, "invalid node timeout policy", %{
       timeout: inspect(other)
     })}
  end

  defp normalize_timeout_policy(opts) do
    with {:ok, timeout} <- TimeoutPolicy.effective_timeout(opts) do
      {:ok, timeout || :infinity, ExecutionPolicy.new!(timeout: timeout || :infinity)}
    end
  end

  defp timeout_policy_options?(opts) when is_list(opts) do
    Enum.any?(opts, fn
      {key, _value} -> timeout_policy_key?(key)
      _other -> false
    end)
  end

  defp timeout_policy_options?(opts) when is_map(opts) do
    opts
    |> Map.keys()
    |> Enum.any?(&timeout_policy_key?/1)
  end

  defp timeout_policy_key?(key) when key in [:run_timeout, :idle_timeout, :refresh_on],
    do: true

  defp timeout_policy_key?(key) when key in ["run_timeout", "idle_timeout", "refresh_on"],
    do: true

  defp timeout_policy_key?(_key), do: false

  defp normalize_cache(false), do: {:ok, false, nil}
  defp normalize_cache(nil), do: {:ok, false, nil}
  defp normalize_cache(true), do: {:ok, true, CachePolicy.new!()}

  defp normalize_cache(%CachePolicy{} = policy) do
    with {:ok, policy} <- CachePolicy.new(policy), do: {:ok, policy, policy}
  end

  defp normalize_cache(opts) when is_list(opts) or is_map(opts) do
    with {:ok, policy} <- CachePolicy.new(opts), do: {:ok, policy, policy}
  end

  defp normalize_cache(cache), do: {:ok, cache, nil}

  defp normalize_deps(nil), do: []
  defp normalize_deps(dep) when is_atom(dep) or is_binary(dep), do: [to_string(dep)]
  defp normalize_deps(deps), do: deps |> List.wrap() |> Enum.map(&to_string/1) |> Enum.uniq()

  defp normalize_destinations(nil), do: []

  defp normalize_destinations(destination) when is_atom(destination) or is_binary(destination),
    do: [to_string(destination)]

  defp normalize_destinations(destinations) when is_map(destinations) do
    Map.new(destinations, fn {target, label} -> {to_string(target), label} end)
  end

  defp normalize_destinations(destinations),
    do: destinations |> List.wrap() |> Enum.map(&to_string/1) |> Enum.uniq()

  defp normalize_metadata(metadata, node) when is_map(metadata),
    do: Map.merge(Map.get(node, :metadata, %{}), metadata)

  defp normalize_metadata(_metadata, node), do: Map.get(node, :metadata, %{})
end
