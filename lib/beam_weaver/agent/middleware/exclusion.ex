defmodule BeamWeaver.Agent.Middleware.Exclusion do
  @moduledoc """
  Validation and filtering helpers for `CapabilityProfile.excluded_middleware`.

  Exclusions may be middleware modules or public middleware names. Module
  entries match exact struct modules; name entries match the middleware's
  reported `name/1` value. The helpers return fresh lists and explicit match
  sets so callers can audit exclusions across multiple assembled stacks.
  """

  alias BeamWeaver.Agent.CapabilityProfile

  @type matches :: %{matched_classes: MapSet.t(module()), matched_names: MapSet.t(String.t())}

  @doc "Raises if a profile attempts to remove required scaffolding middleware."
  @spec validate_config(CapabilityProfile.t() | map() | keyword(), keyword()) :: :ok
  def validate_config(profile_or_opts, opts \\ []) do
    {excluded_classes, excluded_names} = split_exclusions(excluded(profile_or_opts))
    required_classes = opts |> Keyword.get(:required_classes, []) |> MapSet.new()
    required_names = opts |> Keyword.get(:required_names, []) |> normalize_name_set()

    forbidden_classes = MapSet.intersection(excluded_classes, required_classes)
    forbidden_names = MapSet.intersection(excluded_names, required_names)

    if MapSet.size(forbidden_classes) > 0 or MapSet.size(forbidden_names) > 0 do
      labels =
        forbidden_classes
        |> MapSet.to_list()
        |> Enum.map(&module_label/1)
        |> Kernel.++(forbidden_names |> MapSet.to_list() |> Enum.map(&"#{&1} (string)"))
        |> Enum.sort()

      raise ArgumentError,
            "CapabilityProfile.excluded_middleware cannot remove required scaffolding middleware: #{Enum.join(labels, ", ")}"
    end

    :ok
  end

  @doc "Returns a fresh stack with excluded middleware removed."
  @spec drop([term()], CapabilityProfile.t() | map() | keyword()) :: [term()]
  def drop(stack, profile_or_opts) when is_list(stack) do
    {filtered, _matches} = apply_excluded_middleware(stack, profile_or_opts)
    filtered
  end

  @doc """
  Applies exclusions and returns match metadata for later coverage checks.
  """
  @spec apply_excluded_middleware([term()], CapabilityProfile.t() | map() | keyword(), keyword()) ::
          {[term()], matches()}
  def apply_excluded_middleware(stack, profile_or_opts, opts \\ []) when is_list(stack) do
    validate? = Keyword.get(opts, :validate?, false)
    if validate?, do: validate_config(profile_or_opts, opts)

    {excluded_classes, excluded_names} = split_exclusions(excluded(profile_or_opts))

    {filtered, matched_classes, matched_names, name_matched_classes} =
      Enum.reduce(stack, {[], MapSet.new(), MapSet.new(), %{}}, fn middleware,
                                                                   {kept, class_matches, name_matches, name_classes} ->
        module = middleware_module(middleware)
        name = middleware_name(middleware)

        cond do
          not is_nil(module) and MapSet.member?(excluded_classes, module) ->
            {kept, MapSet.put(class_matches, module), name_matches, name_classes}

          not is_nil(name) and MapSet.member?(excluded_names, name) ->
            name_classes =
              Map.update(name_classes, name, MapSet.new([module]), &MapSet.put(&1, module))

            {kept, class_matches, MapSet.put(name_matches, name), name_classes}

          true ->
            {[middleware | kept], class_matches, name_matches, name_classes}
        end
      end)

    raise_on_name_collisions(name_matched_classes)

    {Enum.reverse(filtered), %{matched_classes: matched_classes, matched_names: matched_names}}
  end

  @doc "Raises if any configured exclusion matched no middleware in accumulated matches."
  @spec verify_coverage(CapabilityProfile.t() | map() | keyword(), matches(), keyword()) :: :ok
  def verify_coverage(profile_or_opts, matches, opts \\ []) do
    {excluded_classes, excluded_names} = split_exclusions(excluded(profile_or_opts))
    required_classes = opts |> Keyword.get(:required_classes, []) |> MapSet.new()
    required_names = opts |> Keyword.get(:required_names, []) |> normalize_name_set()

    matched_classes = Map.get(matches, :matched_classes, MapSet.new())
    matched_names = Map.get(matches, :matched_names, MapSet.new())

    unmatched_classes =
      excluded_classes
      |> MapSet.difference(matched_classes)
      |> MapSet.difference(required_classes)

    unmatched_names =
      excluded_names
      |> MapSet.difference(matched_names)
      |> MapSet.difference(required_names)
      |> Enum.reject(&String.starts_with?(&1, "_"))

    if MapSet.size(unmatched_classes) > 0 or unmatched_names != [] do
      labels =
        unmatched_classes
        |> MapSet.to_list()
        |> Enum.map(&module_label/1)
        |> Kernel.++(Enum.map(unmatched_names, &"#{&1} (string)"))
        |> Enum.sort()

      raise ArgumentError,
            "CapabilityProfile.excluded_middleware entries matched no middleware across any assembled stack: #{Enum.join(labels, ", ")}"
    end

    :ok
  end

  @doc "Merges match metadata from multiple stack filtering passes."
  @spec merge_matches(matches(), matches()) :: matches()
  def merge_matches(left, right) do
    %{
      matched_classes:
        MapSet.union(
          Map.get(left, :matched_classes, MapSet.new()),
          Map.get(right, :matched_classes, MapSet.new())
        ),
      matched_names:
        MapSet.union(
          Map.get(left, :matched_names, MapSet.new()),
          Map.get(right, :matched_names, MapSet.new())
        )
    }
  end

  defp split_exclusions(exclusions) do
    Enum.reduce(List.wrap(exclusions), {MapSet.new(), MapSet.new()}, fn
      module, {classes, names} when is_atom(module) ->
        {MapSet.put(classes, module), names}

      name, {classes, names} ->
        {classes, MapSet.put(names, to_string(name))}
    end)
  end

  defp excluded(%CapabilityProfile{excluded_middleware: excluded}), do: excluded
  defp excluded(%{excluded_middleware: excluded}), do: excluded
  defp excluded(%{"excluded_middleware" => excluded}), do: excluded
  defp excluded(opts) when is_list(opts), do: Keyword.get(opts, :excluded_middleware, [])
  defp excluded(_other), do: []

  defp middleware_module(%module{}) when is_atom(module), do: module
  defp middleware_module(module) when is_atom(module), do: module
  defp middleware_module(_middleware), do: nil

  defp middleware_name(%{__struct__: module} = middleware) do
    if function_exported?(module, :name, 1) do
      module.name(middleware) |> to_string()
    else
      module_label(module)
    end
  end

  defp middleware_name(module) when is_atom(module) do
    if function_exported?(module, :name, 1) do
      module.name(module) |> to_string()
    else
      module_label(module)
    end
  end

  defp middleware_name(_middleware), do: nil

  defp raise_on_name_collisions(name_matched_classes) do
    collisions =
      name_matched_classes
      |> Enum.filter(fn {_name, classes} -> MapSet.size(MapSet.delete(classes, nil)) > 1 end)

    if collisions != [] do
      labels =
        collisions
        |> Enum.map(fn {name, classes} ->
          classes =
            classes
            |> MapSet.delete(nil)
            |> Enum.map(&module_label/1)
            |> Enum.sort()

          "#{inspect(name)} matched #{inspect(classes)}"
        end)
        |> Enum.sort()

      raise ArgumentError,
            "CapabilityProfile.excluded_middleware name entry matched multiple distinct middleware classes within a single stack: #{Enum.join(labels, "; ")}"
    end
  end

  defp normalize_name_set(names),
    do: names |> List.wrap() |> Enum.map(&to_string/1) |> MapSet.new()

  defp module_label(module) when is_atom(module) do
    module
    |> Module.split()
    |> List.last()
  rescue
    _exception -> inspect(module)
  end
end
