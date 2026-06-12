defmodule BeamWeaver.Prompt.Variables do
  @moduledoc false

  alias BeamWeaver.Prompt.{
    ChatTemplate,
    DictTemplate,
    FewShotChatTemplate,
    FewShotTemplate,
    ImageTemplate,
    MessagesPlaceholder,
    MessageTemplate,
    StringTemplate,
    StructuredChatTemplate,
    StructuredTemplate,
    Template
  }

  def variables(%StringTemplate{} = prompt) do
    prompt.template
    |> Template.variables_from_template(prompt.template_format)
    |> without_partials(prompt.partials)
  end

  def variables(%MessageTemplate{} = template) do
    template.template
    |> Template.variables_from_template(template.template_format)
    |> without_partials(template.partials)
  end

  def variables(%ChatTemplate{} = prompt) do
    prompt.messages
    |> Enum.flat_map(&variables_from_part(&1, prompt.template_format))
    |> Enum.uniq()
    |> without_partials(prompt.partials)
  end

  def variables(%StructuredTemplate{template: template}), do: variables(template)

  def variables(%StructuredChatTemplate{prompt: prompt}), do: variables(prompt)

  def variables(%FewShotTemplate{} = prompt) do
    [
      Template.variables_from_template(prompt.prefix, prompt.template_format),
      Template.variables_from_template(prompt.suffix, prompt.template_format)
    ]
    |> List.flatten()
    |> Enum.uniq()
    |> without_partials(prompt.partials)
  end

  def variables(%FewShotChatTemplate{} = prompt) do
    [
      Enum.flat_map(prompt.prefix_messages, &variables_from_part(&1, prompt.template_format)),
      Enum.flat_map(prompt.suffix_messages, &variables_from_part(&1, prompt.template_format))
    ]
    |> List.flatten()
    |> Enum.uniq()
    |> without_partials(prompt.partials)
  end

  def variables(_prompt), do: []

  def input_schema(prompt) do
    variables = variables(prompt)
    properties = Map.new(variables, &{&1, %{"type" => "any"}})

    %{"type" => "object", "properties" => properties, "required" => variables}
  end

  defp variables_from_part(%MessageTemplate{} = template, _format), do: variables(template)

  defp variables_from_part(%ImageTemplate{} = template, _format) do
    template.url
    |> Template.variables_from_template(template.template_format)
    |> without_partials(template.partials)
  end

  defp variables_from_part(%DictTemplate{} = template, _format) do
    template.template
    |> Template.variables_from_template(template.template_format)
    |> without_partials(template.partials)
  end

  defp variables_from_part(%MessagesPlaceholder{optional: true}, _format), do: []

  defp variables_from_part(%MessagesPlaceholder{variable_name: variable}, _format),
    do: [Kernel.to_string(variable)]

  defp variables_from_part({_, template}, format), do: Template.variables_from_template(template, format)
  defp variables_from_part(_part, _format), do: []

  defp without_partials(variables, partials) do
    partial_keys = partials |> Map.keys() |> Enum.map(&Kernel.to_string/1) |> MapSet.new()
    Enum.reject(variables, &MapSet.member?(partial_keys, &1))
  end
end
