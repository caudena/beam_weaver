defmodule BeamWeaver.Prompt.Spec do
  @moduledoc false

  import BeamWeaver.MapShape, only: [put_present: 3]

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.Serialization
  alias BeamWeaver.Prompt
  alias BeamWeaver.Result

  def to_spec(%Prompt.StringTemplate{} = prompt) do
    with :ok <- exportable_partials(prompt.partials),
         do: {:ok, templated(prompt, %{"type" => "prompt_string", "template" => prompt.template})}
  end

  def to_spec(%Prompt.ChatTemplate{} = prompt) do
    with :ok <- exportable_partials(prompt.partials),
         {:ok, messages} <- message_specs(prompt.messages, prompt.template_format),
         do: {:ok, templated(prompt, %{"type" => "prompt_chat", "messages" => messages})}
  end

  def to_spec(%Prompt.FewShotTemplate{} = prompt) do
    with :ok <- exportable_partials(prompt.partials),
         :ok <- exportable_selector(prompt.example_selector),
         {:ok, example_prompt} <- maybe_to_spec(prompt.example_prompt) do
      {:ok,
       templated(prompt, %{
         "type" => "prompt_few_shot",
         "examples" => prompt.examples || [],
         "example_prompt" => example_prompt,
         "prefix" => prompt.prefix,
         "suffix" => prompt.suffix,
         "example_separator" => prompt.example_separator
       })}
    end
  end

  def to_spec(%Prompt.FewShotChatTemplate{} = prompt) do
    with :ok <- exportable_partials(prompt.partials),
         :ok <- exportable_selector(prompt.example_selector),
         {:ok, example_prompt} <- maybe_to_spec(prompt.example_prompt),
         {:ok, prefix_messages} <- message_specs(prompt.prefix_messages, prompt.template_format),
         {:ok, suffix_messages} <- message_specs(prompt.suffix_messages, prompt.template_format) do
      {:ok,
       templated(prompt, %{
         "type" => "prompt_few_shot_chat",
         "examples" => prompt.examples || [],
         "example_prompt" => example_prompt,
         "prefix_messages" => prefix_messages,
         "suffix_messages" => suffix_messages
       })}
    end
  end

  def to_spec(%Prompt.MessageTemplate{} = template) do
    with :ok <- exportable_partials(template.partials),
         {:ok, _role} <- role(template.role) do
      spec = %{"kind" => "message_template", "role" => to_string(template.role), "template" => template.template}
      {:ok, templated(template, spec)}
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
      {:ok, templated(template, %{"kind" => "image_template", "url" => template.url, "detail" => template.detail})}
    end
  end

  def to_spec(%Prompt.DictTemplate{} = template) do
    with :ok <- exportable_partials(template.partials),
         do: {:ok, templated(template, %{"kind" => "dict_template", "template" => template.template})}
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

  def to_spec(other) do
    {:error, Error.new(:unsupported_runnable_spec, "prompt part cannot be saved", %{part: inspect(other)})}
  end

  def from_spec(%{"type" => "prompt_string"} = spec),
    do: {:ok, Prompt.string(Map.fetch!(spec, "template"), template_opts(spec))}

  def from_spec(%{"type" => "prompt_chat", "messages" => messages} = spec) do
    with {:ok, messages} <- from_message_specs(messages), do: {:ok, Prompt.chat(messages, template_opts(spec))}
  end

  def from_spec(%{"type" => "prompt_few_shot"} = spec) do
    with {:ok, example_prompt} <- maybe_from_spec(Map.get(spec, "example_prompt")) do
      opts =
        [
          examples: Map.get(spec, "examples", []),
          prefix: Map.get(spec, "prefix"),
          suffix: Map.get(spec, "suffix"),
          example_separator: Map.get(spec, "example_separator", "\n\n")
        ]
        |> Kernel.++(template_opts(spec))
        |> put_present(:example_prompt, example_prompt)

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
          suffix_messages: suffix_messages
        ]
        |> Kernel.++(template_opts(spec))
        |> put_present(:example_prompt, example_prompt)

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
      opts = [structured_output_opts: Map.get(spec, "structured_output_opts", %{})] ++ template_opts(spec)
      {:ok, Prompt.structured_chat(messages, Map.fetch!(spec, "schema"), opts)}
    end
  end

  def from_spec(spec),
    do: {:error, Error.new(:invalid_runnable_spec, "invalid prompt spec", %{spec: spec})}

  defp from_message_spec(%{"kind" => "message_template"} = spec) do
    with {:ok, role} <- role(Map.fetch!(spec, "role")),
         do: {:ok, Prompt.message(role, Map.fetch!(spec, "template"), template_opts(spec))}
  end

  defp from_message_spec(%{"kind" => "messages_placeholder"} = spec) do
    {:ok,
     Prompt.placeholder(Map.fetch!(spec, "variable_name"),
       optional: Map.get(spec, "optional", false),
       max_length: Map.get(spec, "max_length")
     )}
  end

  defp from_message_spec(%{"kind" => "image_template"} = spec),
    do: {:ok, Prompt.image(Map.fetch!(spec, "url"), [detail: Map.get(spec, "detail")] ++ template_opts(spec))}

  defp from_message_spec(%{"kind" => "dict_template"} = spec),
    do: {:ok, Prompt.dict(Map.fetch!(spec, "template"), template_opts(spec))}

  defp from_message_spec(%{"kind" => "message"} = spec), do: spec |> Map.delete("kind") |> Message.from()

  defp from_message_spec(spec),
    do: {:error, Error.new(:invalid_runnable_spec, "invalid prompt message spec", %{spec: spec})}

  defp message_specs(messages, template_format) do
    Result.traverse(messages, &message_spec(&1, template_format))
  end

  defp message_spec({role, template}, template_format),
    do: to_spec(Prompt.message(role, template, template_format: template_format))

  # A literal message is saved as it is, not as a template, so braces in its
  # text stay text.
  defp message_spec(%Message{} = message, _template_format) do
    spec =
      message
      |> Serialization.encode()
      |> Map.drop(["version", "type"])
      |> Map.reject(fn {_key, value} -> value in [%{}, []] end)
      |> Map.put("kind", "message")

    {:ok, spec}
  end

  defp message_spec(%_{} = part, _template_format), do: to_spec(part)

  defp message_spec(part, template_format) do
    with {:ok, message} <- Message.from(part), do: message_spec(message, template_format)
  end

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

  defp templated(template, spec),
    do: Map.merge(spec, %{"partials" => template.partials, "template_format" => to_string(template.template_format)})

  defp template_opts(spec),
    do: [partials: Map.get(spec, "partials", %{}), template_format: format(Map.get(spec, "template_format", "simple"))]

  defp format("simple"), do: :simple
  defp format(other), do: other

  # A template takes the roles `Message.from/1` reads, so a file can't hold a
  # prompt that fails when it is formatted. "developer" stays a string and
  # renders as a system message.
  defp role(role) do
    with {:ok, _message} <- Message.from({role, ""}) do
      {:ok, known_role(role)}
    end
  end

  defp known_role("system"), do: :system
  defp known_role("user"), do: :user
  defp known_role("assistant"), do: :assistant
  defp known_role("tool"), do: :tool
  defp known_role(role), do: role
end
