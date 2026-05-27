defmodule BeamWeaver.Prompt.Rendering do
  @moduledoc false

  alias BeamWeaver.Core.{Error, Message, MessageLike, Messages}
  alias BeamWeaver.Result

  alias BeamWeaver.Prompt.{
    DictTemplate,
    ImageTemplate,
    MessagesPlaceholder,
    MessageTemplate,
    Partials,
    Template
  }

  def render_message_part(part, vars, opts \\ [])

  def render_message_part(%Message{} = message, _vars, _opts), do: {:ok, message}

  def render_message_part(%ImageTemplate{} = template, vars, opts) do
    vars = Map.merge(template.partials, vars)

    with {:ok, url} <-
           Template.render(
             template.url,
             vars,
             Keyword.put(opts, :template_format, template.template_format)
           ) do
      block = %{"type" => "image_url", "image_url" => %{"url" => url}}

      block =
        if template.detail,
          do: put_in(block, ["image_url", "detail"], template.detail),
          else: block

      {:ok, Message.user([block])}
    end
  end

  def render_message_part(%DictTemplate{} = template, vars, opts) do
    vars = Map.merge(template.partials, vars)

    Template.render_dict(
      template.template,
      vars,
      Keyword.put(opts, :template_format, template.template_format)
    )
  end

  def render_message_part(%MessageTemplate{} = template, vars, opts) do
    vars = Map.merge(template.partials, vars)

    with {:ok, content} <-
           Template.render(
             template.template,
             vars,
             Keyword.put(opts, :template_format, template.template_format)
           ) do
      {:ok, message_for_role(template.role, content)}
    end
  end

  def render_message_part(%MessagesPlaceholder{} = placeholder, vars, _opts) do
    case Partials.fetch_var(vars, placeholder.variable_name) do
      {:ok, messages} when is_list(messages) ->
        with {:ok, messages} <- coerce_messages(messages) do
          {:ok, maybe_take_tail(messages, placeholder.max_length)}
        end

      :error ->
        if placeholder.optional,
          do: {:ok, []},
          else:
            {:error,
             Error.new(:prompt_missing_variable, "messages placeholder is missing", %{
               variable: placeholder.variable_name
             })}
    end
  end

  def render_message_part({role, template}, vars, opts) do
    template = %MessageTemplate{
      role: role,
      template: template,
      partials: %{},
      template_format: Keyword.get(opts, :template_format, :simple)
    }

    render_message_part(template, vars, opts)
  end

  def render_message_part(part, _vars, _opts) do
    case MessageLike.to_message(part) do
      {:ok, %Message{} = message} -> {:ok, message}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def render_message_parts(parts, vars, prompt) do
    Result.flat_traverse(List.wrap(parts), &render_message_part(&1, vars, template_format: prompt.template_format))
  end

  def render_optional(nil, _vars, _prompt), do: {:ok, nil}

  def render_optional(template, vars, prompt) do
    Template.render(template, vars, template_format: prompt.template_format)
  end

  defp coerce_messages(messages) do
    Result.traverse(messages, fn item ->
      case MessageLike.to_message(item) do
        {:ok, message} ->
          {:ok, message}

        {:error, %Error{} = error} ->
          {:error,
           Error.new(
             :invalid_prompt_value,
             "messages placeholder contained invalid message",
             %{
               reason: error.message,
               value: inspect(item)
             }
           )}
      end
    end)
  end

  defp maybe_take_tail(messages, nil), do: messages

  defp maybe_take_tail(messages, max_length) when is_integer(max_length) and max_length >= 0,
    do: Enum.take(messages, -max_length)

  defp maybe_take_tail(messages, _max_length), do: messages

  defp role("system"), do: :system
  defp role("user"), do: :user
  defp role("human"), do: :user
  defp role("assistant"), do: :assistant
  defp role("ai"), do: :assistant
  defp role("tool"), do: :tool
  defp role(role), do: role

  defp message_for_role(role, content) do
    case role(role) do
      known when known in [:system, :user, :assistant, :tool] ->
        Message.new!(known, content)

      generic ->
        generic
        |> Messages.chat(content)
        |> Messages.to_message()
    end
  end
end
