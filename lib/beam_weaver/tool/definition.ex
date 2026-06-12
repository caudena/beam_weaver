defmodule BeamWeaver.Tool.Definition do
  @moduledoc false

  defstruct [
    :name,
    :description,
    :fields,
    :injected,
    :response_format,
    :output_schema,
    :tags,
    :metadata,
    :provider_opts,
    :return_direct,
    :concurrent,
    :max_result_chars
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          fields: list(),
          injected: list(),
          response_format: term(),
          output_schema: term(),
          tags: list(),
          metadata: map(),
          provider_opts: map(),
          return_direct: boolean(),
          concurrent: boolean(),
          max_result_chars: non_neg_integer() | :unlimited
        }

  @doc false
  @spec from_module(module()) :: t()
  def from_module(module) when is_atom(module) do
    %__MODULE__{
      name: tool_name(module),
      description: tool_description(module),
      fields: Module.get_attribute(module, :beam_weaver_tool_fields),
      injected: Module.get_attribute(module, :beam_weaver_tool_injected),
      response_format: Module.get_attribute(module, :beam_weaver_tool_response_format),
      output_schema: Module.get_attribute(module, :beam_weaver_tool_output_schema),
      tags: Module.get_attribute(module, :beam_weaver_tool_tags) || [],
      metadata: Module.get_attribute(module, :beam_weaver_tool_metadata) || %{},
      provider_opts: Module.get_attribute(module, :beam_weaver_tool_provider_opts) || %{},
      return_direct: Module.get_attribute(module, :beam_weaver_tool_return_direct) || false,
      concurrent: tool_concurrent(module),
      max_result_chars: Module.get_attribute(module, :beam_weaver_tool_max_result_chars) || :unlimited
    }
  end

  defp tool_name(module) do
    Module.get_attribute(module, :beam_weaver_tool_name) ||
      module |> Module.split() |> List.last() |> Macro.underscore()
  end

  defp tool_description(module) do
    Module.get_attribute(module, :beam_weaver_tool_description) ||
      case Code.fetch_docs(module) do
        {:docs_v1, _, _, _, %{"en" => doc}, _, _} -> doc
        _other -> ""
      end
  end

  defp tool_concurrent(module) do
    case Module.get_attribute(module, :beam_weaver_tool_concurrent) do
      nil -> true
      value -> value
    end
  end
end
