defmodule BeamWeaver.Models.InvocationMetadata do
  @moduledoc false

  defstruct provider: nil,
            model: nil,
            api: nil,
            invocation_params: %{},
            tool_choice: nil,
            bound_tools: [],
            structured_output_mode: nil,
            usage_metadata: nil,
            response_metadata: nil,
            request_metadata: nil,
            param_policy: nil,
            extra: %{}

  @filtered_body_fields [
    "input",
    "input_items",
    "messages",
    "metadata",
    "response_format",
    "text",
    "tools",
    "functions",
    "usage"
  ]

  @filtered_opt_fields [
    :input,
    :input_items,
    :messages,
    :metadata,
    :response_format,
    :structured_output,
    :text,
    :tools,
    :functions
  ]

  @type t :: %__MODULE__{
          provider: atom() | String.t() | nil,
          model: String.t() | nil,
          api: atom() | nil,
          invocation_params: map(),
          tool_choice: term(),
          bound_tools: [String.t()],
          structured_output_mode: term(),
          usage_metadata: map() | nil,
          response_metadata: map() | nil,
          request_metadata: map() | nil,
          param_policy: term(),
          extra: map()
        }

  @spec openai(term(), map(), keyword(), atom()) :: t()
  def openai(model, body, opts, api), do: provider(model, :openai, body, opts, api)

  @spec provider(term(), atom(), map(), keyword(), atom()) :: t()
  def provider(model, provider, body, opts, api) when is_atom(provider) and is_map(body) do
    %__MODULE__{
      provider: provider,
      model: body["model"] || Map.get(model, :model),
      api: api,
      invocation_params: Map.drop(body, @filtered_body_fields),
      tool_choice: body["tool_choice"],
      bound_tools: tool_names(body["tools"]),
      structured_output_mode: structured_output_mode(body),
      usage_metadata: body["usage"],
      request_metadata: body["metadata"],
      param_policy: Keyword.get(opts, :param_policy, Map.get(model, :param_policy)),
      extra: %{
        request_id: body["id"],
        service_tier: body["service_tier"]
      }
    }
  end

  @spec fake(term(), keyword()) :: t()
  def fake(model, opts) do
    %__MODULE__{
      provider: :fake,
      model: "fake-chat",
      api: :fake,
      invocation_params: opts |> Keyword.drop(@filtered_opt_fields) |> Map.new(),
      tool_choice: Keyword.get(opts, :tool_choice),
      bound_tools: tool_names(Keyword.get(opts, :tools)),
      structured_output_mode: structured_output_mode_from_opts(opts),
      usage_metadata: model.usage_metadata,
      param_policy: Keyword.get(opts, :param_policy, model.param_policy)
    }
  end

  @spec to_metadata_map(t()) :: map()
  def to_metadata_map(%__MODULE__{} = metadata) do
    %{
      provider: metadata.provider,
      model_provider: metadata.provider,
      model: metadata.model,
      model_name: metadata.model,
      api: metadata.api,
      invocation_params: metadata.invocation_params,
      tool_choice: metadata.tool_choice,
      bound_tools: metadata.bound_tools,
      structured_output_mode: metadata.structured_output_mode,
      usage_metadata: metadata.usage_metadata,
      response_metadata: metadata.response_metadata,
      request_metadata: metadata.request_metadata,
      param_policy: inspect(metadata.param_policy),
      invocation_metadata: metadata
    }
    |> Map.merge(metadata.extra || %{})
    |> BeamWeaver.MapShape.compact([nil, :empty_list, :empty_map])
  end

  defp tool_names(tools) when is_list(tools) do
    tools
    |> Enum.map(fn
      %{"function" => %{"name" => name}} when is_binary(name) -> name
      %{"name" => name} when is_binary(name) -> name
      %{name: name} when is_binary(name) -> name
      %{"type" => type} when is_binary(type) -> type
      other -> inspect(other)
    end)
    |> Enum.uniq()
  end

  defp tool_names(_tools), do: []

  defp structured_output_mode(%{"text" => %{"format" => %{"type" => type}}}), do: type
  defp structured_output_mode(%{"response_format" => %{"type" => type}}), do: type
  defp structured_output_mode(%{"output_config" => %{"format" => %{"type" => type}}}), do: type
  defp structured_output_mode(_body), do: nil

  defp structured_output_mode_from_opts(opts) do
    cond do
      Keyword.has_key?(opts, :structured_output) -> :structured_output
      Keyword.has_key?(opts, :response_format) -> :response_format
      true -> nil
    end
  end
end
