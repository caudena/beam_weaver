defmodule BeamWeaver.Agent.Middleware.ToolFilter do
  @moduledoc "Filters tools by name before model calls."

  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Core.Tool

  defstruct exclude: [], descriptions: %{}

  def new(opts \\ []),
    do: %__MODULE__{
      exclude: opts |> Keyword.get(:exclude, []) |> List.wrap() |> Enum.map(&to_string/1),
      descriptions:
        opts
        |> Keyword.get(:descriptions, %{})
        |> Map.new(fn {name, description} -> {to_string(name), to_string(description)} end)
    }

  @impl true
  def name(_middleware), do: :deepagents_tool_exclusion

  def wrap_model_call(%__MODULE__{} = middleware, %ModelRequest{} = request, handler) do
    tools =
      request.tools
      |> List.wrap()
      |> Enum.reject(&(Tool.name(&1) in middleware.exclude))
      |> Enum.map(&rewrite_description(&1, middleware.descriptions))

    request |> ModelRequest.override(tools: tools) |> handler.()
  end

  defp rewrite_description(tool, descriptions) when map_size(descriptions) == 0, do: tool

  defp rewrite_description(tool, descriptions) do
    case Map.fetch(descriptions, Tool.name(tool)) do
      {:ok, description} -> put_description(tool, description)
      :error -> tool
    end
  end

  defp put_description(%Tool{} = tool, description), do: %{tool | description: description}

  defp put_description(tool, description) do
    Tool.from_function!(
      name: Tool.name(tool),
      description: description,
      input_schema: Tool.raw_input_schema(tool),
      injected: Tool.injected(tool),
      return_direct: Tool.return_direct(tool),
      response_format: Tool.response_format(tool),
      output_schema: Tool.output_schema(tool),
      handle_tool_error: Tool.handle_tool_error(tool),
      handle_validation_error: Tool.handle_validation_error(tool),
      parse_args: fn args -> Tool.parse_args(tool, args) end,
      concurrent: Tool.concurrent?(tool),
      max_result_chars: Tool.max_result_chars(tool),
      tags: Tool.tags(tool),
      metadata: Tool.metadata(tool),
      provider_opts: Tool.provider_opts(tool),
      handler: fn input, opts -> Tool.invoke(tool, input, Keyword.put(opts, :trace?, false)) end
    )
  end
end
