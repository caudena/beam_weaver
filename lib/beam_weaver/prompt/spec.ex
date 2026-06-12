defmodule BeamWeaver.Prompt.Spec do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Prompt
  alias BeamWeaver.Result

  def to_spec(%Prompt.StringTemplate{} = prompt) do
    with :ok <- exportable_partials(prompt.partials) do
      {:ok,
       %{
         "type" => "prompt_string",
         "template" => prompt.template,
         "partials" => prompt.partials,
         "template_format" => to_string(prompt.template_format)
       }}
    end
  end

  def to_spec(%Prompt.ChatTemplate{} = prompt) do
    with :ok <- exportable_partials(prompt.partials),
         {:ok, messages} <- message_specs(prompt.messages, prompt.template_format) do
      {:ok,
       %{
         "type" => "prompt_chat",
         "messages" => messages,
         "partials" => prompt.partials,
         "template_format" => to_string(prompt.template_format)
       }}
    end
  end

  def to_spec(%Prompt.FewShotTemplate{} = prompt) do
    with :ok <- exportable_partials(prompt.partials),
         :ok <- exportable_selector(prompt.example_selector),
         {:ok, example_prompt} <- maybe_to_spec(prompt.example_prompt) do
      {:ok,
       %{
         "type" => "prompt_few_shot",
         "examples" => prompt.examples || [],
         "example_prompt" => example_prompt,
         "prefix" => prompt.prefix,
         "suffix" => prompt.suffix,
         "example_separator" => prompt.example_separator,
         "partials" => prompt.partials,
         "template_format" => to_string(prompt.template_format)
       }}
    end
  end

  def to_spec(%Prompt.FewShotChatTemplate{} = prompt) do
    with :ok <- exportable_partials(prompt.partials),
         :ok <- exportable_selector(prompt.example_selector),
         {:ok, example_prompt} <- maybe_to_spec(prompt.example_prompt),
         {:ok, prefix_messages} <- message_specs(prompt.prefix_messages, prompt.template_format),
         {:ok, suffix_messages} <- message_specs(prompt.suffix_messages, prompt.template_format) do
      {:ok,
       %{
         "type" => "prompt_few_shot_chat",
         "examples" => prompt.examples || [],
         "example_prompt" => example_prompt,
         "prefix_messages" => prefix_messages,
         "suffix_messages" => suffix_messages,
         "partials" => prompt.partials,
         "template_format" => to_string(prompt.template_format)
       }}
    end
  end

  def to_spec(%Prompt.MessageTemplate{} = template) do
    with :ok <- exportable_partials(template.partials) do
      {:ok,
       %{
         "kind" => "message_template",
         "role" => to_string(template.role),
         "template" => template.template,
         "partials" => template.partials,
         "template_format" => to_string(template.template_format)
       }}
    end
  end

  def to_spec(%Prompt.MessagesPlaceholder{} = placeholder) do
    {:ok,
     %{
       "kind" => "messages_placeholder",
       "variable_name" => to_string(placeholder.variable_name),
       "optional" => placeholder.optional,
       "max_length" => placeholder.max_length
     }}
  end

  def to_spec(%Prompt.ImageTemplate{} = template) do
    with :ok <- exportable_partials(template.partials) do
      {:ok,
       %{
         "kind" => "image_template",
         "url" => template.url,
         "detail" => template.detail,
         "partials" => template.partials,
         "template_format" => to_string(template.template_format)
       }}
    end
  end

  def to_spec(%Prompt.DictTemplate{} = template) do
    with :ok <- exportable_partials(template.partials) do
      {:ok,
       %{
         "kind" => "dict_template",
         "template" => template.template,
         "partials" => template.partials,
         "template_format" => to_string(template.template_format)
       }}
    end
  end

  def to_spec(%Prompt.StructuredTemplate{} = prompt) do
    with {:ok, template} <- to_spec(prompt.template) do
      {:ok,
       %{
         "type" => "prompt_structured",
         "schema" => prompt.schema,
         "template" => template
       }}
    end
  end

  def to_spec(%Prompt.StructuredChatTemplate{} = prompt) do
    with {:ok, chat_spec} <- to_spec(prompt.prompt) do
      {:ok,
       chat_spec
       |> Map.put("type", "prompt_structured_chat")
       |> Map.put("schema", prompt.schema)
       |> Map.put("structured_output_opts", Map.new(prompt.structured_output_opts))}
    end
  end

  def from_spec(%{"type" => "prompt_string"} = spec) do
    {:ok,
     Prompt.string(Map.fetch!(spec, "template"),
       partials: Map.get(spec, "partials", %{}),
       template_format: format(Map.get(spec, "template_format", "simple"))
     )}
  end

  def from_spec(%{"type" => "prompt_chat", "messages" => messages} = spec) do
    with {:ok, messages} <- from_message_specs(messages) do
      {:ok,
       Prompt.chat(messages,
         partials: Map.get(spec, "partials", %{}),
         template_format: format(Map.get(spec, "template_format", "simple"))
       )}
    end
  end

  def from_spec(%{"type" => "prompt_few_shot"} = spec) do
    with {:ok, example_prompt} <- maybe_from_spec(Map.get(spec, "example_prompt")) do
      opts =
        [
          examples: Map.get(spec, "examples", []),
          prefix: Map.get(spec, "prefix"),
          suffix: Map.get(spec, "suffix"),
          example_separator: Map.get(spec, "example_separator", "\n\n"),
          partials: Map.get(spec, "partials", %{}),
          template_format: format(Map.get(spec, "template_format", "simple"))
        ]
        |> maybe_put(:example_prompt, example_prompt)

      {:ok, Prompt.few_shot(opts)}
    end
  end

  def from_spec(%{"type" => "prompt_few_shot_chat"} = spec) do
    with {:ok, example_prompt} <- maybe_from_spec(Map.get(spec, "example_prompt")),
         {:ok, prefix_messages} <- from_message_specs(Map.get(spec, "prefix_messages", [])),
         {:ok, suffix_messages} <- from_message_specs(Map.get(spec, "suffix_messages", [])) do
      opts =
        [
          examples: Map.get(spec, "examples", []),
          prefix_messages: prefix_messages,
          suffix_messages: suffix_messages,
          partials: Map.get(spec, "partials", %{}),
          template_format: format(Map.get(spec, "template_format", "simple"))
        ]
        |> maybe_put(:example_prompt, example_prompt)

      {:ok, Prompt.few_shot_chat(opts)}
    end
  end

  def from_spec(%{"type" => "prompt_structured", "template" => template} = spec) do
    with {:ok, template} <- from_spec(template) do
      {:ok, Prompt.structured(Map.fetch!(spec, "schema"), template)}
    end
  end

  def from_spec(%{"type" => "prompt_structured_chat", "messages" => messages} = spec) do
    with {:ok, messages} <- from_message_specs(messages) do
      {:ok,
       Prompt.structured_chat(messages, Map.fetch!(spec, "schema"),
         partials: Map.get(spec, "partials", %{}),
         template_format: format(Map.get(spec, "template_format", "simple")),
         structured_output_opts: Map.get(spec, "structured_output_opts", %{})
       )}
    end
  end

  def from_spec(spec),
    do: {:error, Error.new(:invalid_runnable_spec, "invalid prompt spec", %{spec: spec})}

  def from_message_spec(%{"kind" => "message_template"} = spec) do
    {:ok,
     Prompt.message(role(Map.fetch!(spec, "role")), Map.fetch!(spec, "template"),
       partials: Map.get(spec, "partials", %{}),
       template_format: format(Map.get(spec, "template_format", "simple"))
     )}
  end

  def from_message_spec(%{"kind" => "messages_placeholder"} = spec) do
    {:ok,
     Prompt.placeholder(Map.fetch!(spec, "variable_name"),
       optional: Map.get(spec, "optional", false),
       max_length: Map.get(spec, "max_length")
     )}
  end

  def from_message_spec(%{"kind" => "image_template"} = spec) do
    {:ok,
     Prompt.image(Map.fetch!(spec, "url"),
       detail: Map.get(spec, "detail"),
       partials: Map.get(spec, "partials", %{}),
       template_format: format(Map.get(spec, "template_format", "simple"))
     )}
  end

  def from_message_spec(%{"kind" => "dict_template"} = spec) do
    {:ok,
     Prompt.dict(Map.fetch!(spec, "template"),
       partials: Map.get(spec, "partials", %{}),
       template_format: format(Map.get(spec, "template_format", "simple"))
     )}
  end

  def from_message_spec(spec),
    do: {:error, Error.new(:invalid_runnable_spec, "invalid prompt message spec", %{spec: spec})}

  defp message_specs(messages, template_format) do
    Result.traverse(messages, &message_spec(&1, template_format))
  end

  defp message_spec({role, template}, template_format),
    do: to_spec(Prompt.message(role, template, template_format: template_format))

  defp message_spec(message, _template_format), do: to_spec(message)

  defp from_message_specs(messages) do
    Result.traverse(messages, &from_message_spec/1)
  end

  defp exportable_partials(partials) do
    partials
    |> Enum.find(fn {_key, value} -> is_function(value) end)
    |> case do
      nil ->
        :ok

      {key, _value} ->
        {:error,
         Error.new(:unsupported_runnable_spec, "anonymous prompt partials cannot be exported", %{
           partial: key
         })}
    end
  end

  defp exportable_selector(nil), do: :ok

  defp exportable_selector(_selector) do
    {:error, Error.new(:unsupported_runnable_spec, "example selectors cannot be exported", %{})}
  end

  defp maybe_to_spec(nil), do: {:ok, nil}
  defp maybe_to_spec(prompt), do: to_spec(prompt)

  defp maybe_from_spec(nil), do: {:ok, nil}
  defp maybe_from_spec(spec), do: from_spec(spec)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp format("simple"), do: :simple
  defp format(:simple), do: :simple
  defp format(other), do: other

  defp role("system"), do: :system
  defp role("user"), do: :user
  defp role("human"), do: :user
  defp role("assistant"), do: :assistant
  defp role("ai"), do: :assistant
  defp role("tool"), do: :tool
  defp role(role), do: role
end
