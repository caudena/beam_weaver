defmodule BeamWeaver.Graph.StateGraph.Normalization do
  @moduledoc false

  alias BeamWeaver.Graph.Channels.BinaryOperatorAggregate
  alias BeamWeaver.Graph.ChannelSpec

  def normalize_reducers(reducers) do
    Map.new(reducers, fn {key, reducer} -> {state_key(key), reducer} end)
  end

  def reducer_channels(reducers) do
    reducers
    |> Enum.filter(fn {_key, reducer} -> is_function(reducer, 2) end)
    |> Map.new(fn {key, reducer} ->
      {key, BinaryOperatorAggregate.new(reducer, key: key)}
    end)
  end

  def normalize_channel_defs(defs) when defs in [%{}, nil], do: %{}

  def normalize_channel_defs(defs) do
    Map.new(defs, fn {key, channel} ->
      key = state_key(key)
      {key, normalize_channel(channel, key, [])}
    end)
  end

  def channels_from_schema(nil), do: {%{}, %{}, %{}, %{}}

  def channels_from_schema(schema) when is_map(schema) do
    Enum.reduce(schema, {%{}, %{}, %{}, %{}}, fn {key, spec}, {channels, subscriptions, visibility, managed} ->
      key = state_key(key)

      case schema_channel_entry(key, spec) do
        nil ->
          {channels, subscriptions, visibility, managed}

        {:managed, managed_value} ->
          {channels, subscriptions, visibility, Map.put(managed, key, managed_value)}

        {channel, subscribers, channel_visibility} ->
          {
            Map.put(channels, key, channel),
            merge_channel_subscriptions(subscriptions, %{to_string(key) => subscribers}),
            Map.put(visibility, key, channel_visibility),
            managed
          }
      end
    end)
  end

  def channels_from_schema(_schema), do: {%{}, %{}, %{}, %{}}

  def normalize_channel(%{__struct__: module} = channel, key, _opts) do
    if Map.has_key?(channel, :key),
      do: struct(module, Map.put(Map.from_struct(channel), :key, key)),
      else: channel
  end

  def normalize_channel({module, arg}, key, opts) when is_atom(module) do
    module.new(arg, Keyword.put(opts, :key, key))
  end

  def normalize_channel({module, arg, channel_opts}, key, opts) when is_atom(module) do
    module.new(arg, Keyword.merge(channel_opts, Keyword.put(opts, :key, key)))
  end

  def normalize_channel(module, key, opts) when is_atom(module) do
    module.new(Keyword.put(opts, :key, key))
  end

  def normalize_channel(channel, _key, _opts), do: channel

  def normalize_managed(%{__struct__: module} = managed, key) do
    if Map.has_key?(managed, :key),
      do: struct(module, Map.put(Map.from_struct(managed), :key, key)),
      else: managed
  end

  def normalize_managed(module, key) when is_atom(module), do: module.new(key: key)
  def normalize_managed(managed, _key), do: managed

  def merge_channel_subscriptions(left, right) do
    Enum.reduce(right, left, fn {channel, subscribers}, acc ->
      subscribers = normalize_subscribers(subscribers)

      if subscribers == [] do
        Map.put_new(acc, to_string(channel), [])
      else
        Map.update(acc, to_string(channel), subscribers, fn existing ->
          Enum.uniq(existing ++ subscribers)
        end)
      end
    end)
  end

  def normalize_subscribers(nil), do: []

  def normalize_subscribers(subscriber) when is_atom(subscriber) or is_binary(subscriber),
    do: [normalize_node(subscriber)]

  def normalize_subscribers(subscribers),
    do: subscribers |> List.wrap() |> Enum.map(&normalize_node/1) |> Enum.uniq()

  def normalize_visibility(:private), do: :private
  def normalize_visibility("private"), do: :private
  def normalize_visibility(true), do: :private
  def normalize_visibility(_visibility), do: :public

  def maybe_normalize_node(nil), do: nil
  def maybe_normalize_node(node), do: normalize_node(node)

  def normalize_node(:__start__), do: "__start__"
  def normalize_node(:__end__), do: "__end__"
  def normalize_node(node), do: to_string(node)

  def state_key(key) when is_atom(key), do: key
  def state_key(key) when is_binary(key), do: key

  defp schema_channel_entry(key, %ChannelSpec{managed?: true, channel: managed}) do
    {:managed, normalize_managed(managed, key)}
  end

  defp schema_channel_entry(key, %ChannelSpec{} = spec) do
    {normalize_channel(spec.channel, key, spec.opts), normalize_subscribers(spec.subscribers), spec.visibility}
  end

  defp schema_channel_entry(key, spec) when is_list(spec) do
    if Keyword.keyword?(spec) do
      channel = Keyword.get(spec, :channel, Keyword.get(spec, :type))
      opts = Keyword.drop(spec, [:channel, :type, :subscriber, :subscribers, :triggers])
      subscribers = schema_subscribers(spec)

      visibility =
        normalize_visibility(Keyword.get(spec, :visibility, Keyword.get(spec, :private, :public)))

      if channel,
        do: {normalize_channel(channel, key, opts), subscribers, visibility},
        else: nil
    else
      nil
    end
  end

  defp schema_channel_entry(key, spec) when is_map(spec) and not is_struct(spec) do
    channel =
      Map.get(
        spec,
        :channel,
        Map.get(spec, "channel", Map.get(spec, :type, Map.get(spec, "type")))
      )

    subscribers = schema_subscribers(spec)

    visibility =
      Map.get(
        spec,
        :visibility,
        Map.get(spec, "visibility", Map.get(spec, :private, Map.get(spec, "private", :public)))
      )
      |> normalize_visibility()

    opts =
      spec
      |> Enum.reject(fn {option, _value} ->
        option in [
          :channel,
          "channel",
          :type,
          "type",
          :subscriber,
          "subscriber",
          :subscribers,
          "subscribers",
          :triggers,
          "triggers",
          :visibility,
          "visibility",
          :private,
          "private"
        ]
      end)
      |> Enum.map(fn {option, value} -> {option_key(option), value} end)

    if channel,
      do: {normalize_channel(channel, key, opts), subscribers, visibility},
      else: nil
  end

  defp schema_channel_entry(key, %{__struct__: _module} = channel) do
    {normalize_channel(channel, key, []), [], :public}
  end

  defp schema_channel_entry(_key, _spec), do: nil

  defp schema_subscribers(spec) when is_list(spec) do
    spec
    |> Keyword.get(:subscribers, Keyword.get(spec, :subscriber, Keyword.get(spec, :triggers, [])))
    |> normalize_subscribers()
  end

  defp schema_subscribers(spec) when is_map(spec) do
    Map.get(
      spec,
      :subscribers,
      Map.get(
        spec,
        "subscribers",
        Map.get(
          spec,
          :subscriber,
          Map.get(spec, "subscriber", Map.get(spec, :triggers, Map.get(spec, "triggers", [])))
        )
      )
    )
    |> normalize_subscribers()
  end

  defp option_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp option_key(key), do: key
end
