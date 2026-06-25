defmodule BeamWeaver.Sandbox.Provider do
  @moduledoc """
  Behaviour for native sandbox provider constructors.

  Providers build normal `BeamWeaver.Sandbox` backends. The registry is a
  configuration and validation boundary, not a second execution API.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Sandbox.ProviderSpec

  @callback build(ProviderSpec.t(), keyword()) :: {:ok, term()} | {:error, Error.t()} | term()
end

defmodule BeamWeaver.Sandbox.ProviderSpec do
  @moduledoc """
  Native sandbox provider declaration.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Tracing.Redactor

  @enforce_keys [:id, :module]
  defstruct [:id, :module, config: %{}, capabilities: %{}, metadata: %{}]

  @type id :: String.t()
  @type t :: %__MODULE__{
          id: id(),
          module: module(),
          config: map(),
          capabilities: map(),
          metadata: map()
        }

  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = spec), do: validate(spec)

  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    spec = %__MODULE__{
      id: normalize_id(attrs[:id] || attrs["id"]),
      module: attrs[:module] || attrs["module"],
      config: normalize_map(attrs[:config] || attrs["config"] || %{}),
      capabilities: normalize_capabilities(attrs[:capabilities] || attrs["capabilities"] || %{}),
      metadata: normalize_map(attrs[:metadata] || attrs["metadata"] || %{})
    }

    validate(spec)
  end

  def new(_attrs),
    do: {:error, Error.new(:invalid_sandbox_provider, "provider spec must be a map or keyword list")}

  @spec to_metadata(t()) :: map()
  def to_metadata(%__MODULE__{} = spec) do
    %{
      id: spec.id,
      module: spec.module,
      capabilities: spec.capabilities,
      config: Redactor.redact(spec.config),
      metadata: Redactor.redact(spec.metadata)
    }
  end

  @spec capability?(t(), atom() | String.t()) :: boolean()
  def capability?(%__MODULE__{capabilities: capabilities}, capability) do
    Map.get(capabilities, to_string(capability)) == true
  end

  defp validate(%__MODULE__{id: id}) when id in [nil, ""],
    do: {:error, Error.new(:invalid_sandbox_provider, "provider id is required")}

  defp validate(%__MODULE__{module: module}) when not is_atom(module),
    do: {:error, Error.new(:invalid_sandbox_provider, "provider module is required")}

  defp validate(%__MODULE__{module: module} = spec) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error,
         Error.new(:invalid_sandbox_provider, "provider module could not be loaded", %{
           module: module
         })}

      not function_exported?(module, :build, 2) ->
        {:error,
         Error.new(:invalid_sandbox_provider, "provider module must implement build/2", %{
           module: module
         })}

      true ->
        {:ok, spec}
    end
  end

  defp normalize_id(nil), do: nil
  defp normalize_id(id), do: id |> to_string() |> String.trim()

  defp normalize_map(values) when is_list(values), do: Map.new(values)
  defp normalize_map(values) when is_map(values), do: values
  defp normalize_map(_values), do: %{}

  defp normalize_capabilities(values) when is_list(values) do
    values
    |> Enum.map(fn
      {key, value} -> {to_string(key), value == true}
      key -> {to_string(key), true}
    end)
    |> Map.new()
  end

  defp normalize_capabilities(values) when is_map(values) do
    Map.new(values, fn {key, value} -> {to_string(key), value == true} end)
  end

  defp normalize_capabilities(_values), do: %{}
end

defimpl Inspect, for: BeamWeaver.Sandbox.ProviderSpec do
  import Inspect.Algebra

  def inspect(spec, opts) do
    concat(["#BeamWeaver.Sandbox.ProviderSpec<", to_doc(BeamWeaver.Sandbox.ProviderSpec.to_metadata(spec), opts), ">"])
  end
end

defmodule BeamWeaver.Sandbox.LocalProvider do
  @moduledoc false

  @behaviour BeamWeaver.Sandbox.Provider

  alias BeamWeaver.Sandbox
  alias BeamWeaver.Sandbox.ProviderSpec

  @impl true
  def build(%ProviderSpec{config: config}, opts) do
    opts =
      config
      |> to_keyword()
      |> Keyword.merge(opts)

    {:ok, Sandbox.local(opts)}
  end

  defp to_keyword(values) when is_list(values), do: values

  defp to_keyword(values) when is_map(values) do
    Enum.map(values, fn {key, value} -> {key_atom(key), value} end)
  end

  defp key_atom(key) when is_atom(key), do: key

  defp key_atom(key) do
    key
    |> to_string()
    |> String.to_existing_atom()
  rescue
    ArgumentError -> key
  end
end

defmodule BeamWeaver.Sandbox.Registry do
  @moduledoc """
  Registry for native sandbox providers.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Sandbox
  alias BeamWeaver.Sandbox.ProviderSpec

  defstruct providers: %{}

  @type t :: %__MODULE__{providers: %{String.t() => ProviderSpec.t()}}

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) do
    builtin? = Keyword.get(opts, :builtin, true)
    configured = Keyword.get(opts, :providers, [])
    specs = if builtin?, do: builtin_specs() ++ configured, else: configured

    Enum.reduce_while(specs, {:ok, %__MODULE__{}}, fn spec, {:ok, registry} ->
      case register(registry, spec) do
        {:ok, registry} -> {:cont, {:ok, registry}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, registry} -> registry
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec builtin_specs() :: [ProviderSpec.t()]
  def builtin_specs do
    [
      %ProviderSpec{
        id: "local",
        module: BeamWeaver.Sandbox.LocalProvider,
        capabilities: %{
          "working_dir" => true,
          "sandbox_id" => false,
          "snapshot" => false,
          "mounts" => false
        },
        metadata: %{kind: :local}
      }
    ]
  end

  @spec register(t(), ProviderSpec.t() | map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def register(%__MODULE__{} = registry, spec_attrs) do
    with {:ok, %ProviderSpec{} = spec} <- ProviderSpec.new(spec_attrs),
         :ok <- reject_duplicate(registry, spec) do
      {:ok, %{registry | providers: Map.put(registry.providers, spec.id, spec)}}
    end
  end

  @spec list(t()) :: [ProviderSpec.t()]
  def list(%__MODULE__{} = registry) do
    registry.providers
    |> Map.values()
    |> Enum.sort_by(& &1.id)
  end

  @spec fetch(t(), ProviderSpec.id() | atom()) :: {:ok, ProviderSpec.t()} | {:error, Error.t()}
  def fetch(%__MODULE__{} = registry, id) do
    case Map.fetch(registry.providers, normalize_id(id)) do
      {:ok, spec} ->
        {:ok, spec}

      :error ->
        {:error,
         Error.new(:unknown_sandbox_provider, "sandbox provider is not registered", %{
           provider: normalize_id(id)
         })}
    end
  end

  @spec build(t(), ProviderSpec.id() | atom(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def build(%__MODULE__{} = registry, id, opts \\ []) do
    with {:ok, spec} <- fetch(registry, id),
         :ok <- validate_lifecycle_options(spec, opts),
         {:ok, sandbox} <- do_build(spec, opts),
         :ok <- validate_sandbox_backend(sandbox, spec) do
      {:ok, sandbox}
    end
  end

  @spec metadata(t()) :: [map()]
  def metadata(%__MODULE__{} = registry) do
    registry
    |> list()
    |> Enum.map(&ProviderSpec.to_metadata/1)
  end

  defp do_build(%ProviderSpec{module: module} = spec, opts) do
    case module.build(spec, opts) do
      {:ok, sandbox} -> {:ok, sandbox}
      {:error, %Error{} = error} -> {:error, error}
      sandbox -> {:ok, sandbox}
    end
  rescue
    exception ->
      {:error,
       Error.new(:sandbox_provider_build_failed, "sandbox provider failed to build", %{
         provider: spec.id,
         error: Exception.message(exception)
       })}
  end

  defp reject_duplicate(%__MODULE__{providers: providers}, %ProviderSpec{id: id}) do
    if Map.has_key?(providers, id) do
      {:error, Error.new(:duplicate_sandbox_provider, "sandbox provider is already registered", %{provider: id})}
    else
      :ok
    end
  end

  defp validate_lifecycle_options(%ProviderSpec{} = spec, opts) do
    unsupported =
      []
      |> maybe_unsupported(spec, opts, :sandbox_id, :sandbox_id)
      |> maybe_unsupported(spec, opts, :snapshot_id, :snapshot)
      |> maybe_unsupported(spec, opts, :snapshot_name, :snapshot)
      |> maybe_unsupported(spec, opts, :mounts, :mounts)
      |> maybe_unsupported(spec, opts, :working_dir, :working_dir)

    case unsupported do
      [] ->
        :ok

      unsupported ->
        {:error,
         Error.new(
           :unsupported_sandbox_provider_option,
           "sandbox provider does not support requested lifecycle options",
           %{
             provider: spec.id,
             options: Enum.reverse(unsupported)
           }
         )}
    end
  end

  defp maybe_unsupported(unsupported, spec, opts, option, capability) do
    if Keyword.has_key?(opts, option) and not ProviderSpec.capability?(spec, capability),
      do: [option | unsupported],
      else: unsupported
  end

  defp validate_sandbox_backend(sandbox, spec) do
    if Sandbox.Backend.impl_for(sandbox) do
      :ok
    else
      {:error,
       Error.new(:invalid_sandbox_provider_backend, "sandbox provider did not build a sandbox backend", %{
         provider: spec.id,
         backend: inspect(sandbox)
       })}
    end
  end

  defp normalize_id(id), do: id |> to_string() |> String.trim()
end

defimpl Inspect, for: BeamWeaver.Sandbox.Registry do
  import Inspect.Algebra

  def inspect(registry, opts) do
    concat(["#BeamWeaver.Sandbox.Registry<", to_doc(BeamWeaver.Sandbox.Registry.metadata(registry), opts), ">"])
  end
end
