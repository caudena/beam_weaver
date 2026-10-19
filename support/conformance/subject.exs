defmodule BeamWeaver.TestSupport.Conformance.Subject do
  @moduledoc """
  Explicit conformance-test subject.
  """

  defstruct build: nil, capabilities: [], fixtures: %{}

  @type t :: %__MODULE__{build: term(), capabilities: [atom()], fixtures: map()}

  @doc """
  Resolves a conformance subject value: calls it when it is a 0-arity builder,
  otherwise returns it as-is.
  """
  @spec standard_value(term()) :: term()
  def standard_value(value) when is_function(value, 0), do: value.()
  def standard_value(value), do: value

  @spec new(keyword() | map() | t(), atom()) :: t()
  def new(%__MODULE__{} = subject, kind) do
    %{subject | fixtures: default_fixtures(kind) |> Map.merge(subject.fixtures || %{})}
  end

  def new(opts, kind) when is_list(opts) do
    opts
    |> Map.new()
    |> new(kind)
  end

  def new(%{subject: %__MODULE__{} = subject}, kind), do: new(subject, kind)

  def new(%{} = opts, kind) do
    %__MODULE__{
      build: Map.get(opts, :build) || legacy_build(opts, kind),
      capabilities: List.wrap(Map.get(opts, :capabilities, [])),
      fixtures: opts |> Map.get(:fixtures, %{}) |> Map.new() |> Map.merge(legacy_fixtures(opts, kind))
    }
  end

  @spec build(t() | term()) :: term()
  def build(%__MODULE__{build: build}), do: build_value(build)
  def build(value), do: build_value(value)

  @spec capability?(t(), atom()) :: boolean()
  def capability?(%__MODULE__{capabilities: capabilities}, capability),
    do: capability in capabilities

  @spec fixture(t(), atom(), term()) :: term()
  def fixture(%__MODULE__{fixtures: fixtures}, key, default \\ nil), do: Map.get(fixtures, key, default)

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

  defp legacy_build(opts, kind) when kind in [:llm, :embedding_model], do: Map.get(opts, :model)
  defp legacy_build(opts, :tool), do: Map.get(opts, :tool)
  defp legacy_build(_opts, _kind), do: nil

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
end
