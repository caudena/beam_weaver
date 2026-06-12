defmodule BeamWeaver.TestSupport.Conformance.Subject do
  @moduledoc """
  Explicit conformance-test subject.

  This keeps BeamWeaver's standard tests data-driven instead of mirroring
  Python's inheritance-based test classes.
  """

  defstruct build: nil, capabilities: [], fixtures: %{}, assertions: %{}

  @type t :: %__MODULE__{
          build: term(),
          capabilities: [atom()],
          fixtures: map(),
          assertions: map()
        }

  @spec new(keyword() | map() | t(), atom()) :: t()
  def new(%__MODULE__{} = subject, kind) do
    %{subject | fixtures: default_fixtures(kind) |> Map.merge(subject.fixtures || %{})}
  end

  def new(opts, kind) when is_list(opts) do
    opts
    |> Map.new()
    |> new(kind)
  end

  def new(%{} = opts, kind) do
    subject = Map.get(opts, :subject) || Map.get(opts, "subject")

    cond do
      match?(%__MODULE__{}, subject) ->
        new(subject, kind)

      is_map(subject) or is_list(subject) ->
        new(subject, kind)

      true ->
        %__MODULE__{
          build: Map.get(opts, :build) || Map.get(opts, "build") || legacy_build(opts, kind),
          capabilities: normalize_capabilities(Map.get(opts, :capabilities, [])),
          fixtures:
            normalize_map(Map.get(opts, :fixtures, %{})) |> Map.merge(legacy_fixtures(opts, kind)),
          assertions: normalize_map(Map.get(opts, :assertions, %{}))
        }
    end
  end

  @spec build(t() | term()) :: term()
  def build(%__MODULE__{build: build}), do: build_value(build)
  def build(value), do: build_value(value)

  @spec capability?(t(), atom()) :: boolean()
  def capability?(%__MODULE__{capabilities: capabilities}, capability),
    do: capability in capabilities

  @spec fixture(t(), atom(), term()) :: term()
  def fixture(%__MODULE__{fixtures: fixtures}, key, default \\ nil) do
    Map.get(fixtures, key, Map.get(fixtures, Atom.to_string(key), default))
  end

  @spec assertion(t(), atom(), term()) :: term()
  def assertion(%__MODULE__{assertions: assertions}, key, default \\ nil) do
    Map.get(assertions, key, Map.get(assertions, Atom.to_string(key), default))
  end

  defp build_value(fun) when is_function(fun, 0), do: fun.()

  defp build_value({module, opts}) when is_atom(module) and is_list(opts),
    do: struct(module, realize_runtime_values(opts))

  defp build_value(value), do: value

  defp realize_runtime_values(values) when is_list(values) do
    Enum.map(values, fn
      {key, :__beamweaver_self__} -> {key, self()}
      {key, value} -> {key, realize_runtime_values(value)}
      value -> realize_runtime_values(value)
    end)
  end

  defp realize_runtime_values(value), do: value

  defp legacy_build(opts, :chat_model), do: Map.get(opts, :model)
  defp legacy_build(opts, :llm), do: Map.get(opts, :model)
  defp legacy_build(opts, :embedding_model), do: Map.get(opts, :model)
  defp legacy_build(opts, :tool), do: Map.get(opts, :tool)
  defp legacy_build(opts, _kind), do: Map.get(opts, :build)

  defp legacy_fixtures(opts, :chat_model) do
    default_fixtures(:chat_model)
    |> Map.put(:messages, Map.get(opts, :messages, default_fixtures(:chat_model).messages))
    |> maybe_put(:invalid_param_opts, Map.get(opts, :invalid_param_opts))
  end

  defp legacy_fixtures(opts, :llm) do
    Map.put(default_fixtures(:llm), :prompt, Map.get(opts, :prompt, "Say hello"))
  end

  defp legacy_fixtures(opts, :embedding_model) do
    defaults = default_fixtures(:embedding_model)

    %{
      documents: Map.get(opts, :documents, defaults.documents),
      query: Map.get(opts, :query, defaults.query)
    }
  end

  defp legacy_fixtures(opts, :tool) do
    %{input: Map.get(opts, :input)}
  end

  defp legacy_fixtures(_opts, _kind), do: %{}

  defp default_fixtures(:chat_model), do: %{messages: [BeamWeaver.Core.Message.user("hello")]}
  defp default_fixtures(:llm), do: %{prompt: "Say hello"}
  defp default_fixtures(:embedding_model), do: %{documents: ["alpha", "beta"], query: "alpha"}
  defp default_fixtures(_kind), do: %{}

  defp normalize_capabilities(values), do: values |> List.wrap() |> Enum.map(&normalize_atom/1)

  defp normalize_atom(value) when is_atom(value), do: value

  defp normalize_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> raise ArgumentError, "unknown conformance capability: #{value}"
  end

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(value) when is_list(value), do: Map.new(value)
  defp normalize_map(_value), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
