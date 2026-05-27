defmodule BeamWeaver.Prompt do
  @moduledoc """
  Runnable-compatible prompt primitives.
  """

  import Kernel, except: [to_string: 1]

  alias BeamWeaver.Core.Error

  alias BeamWeaver.Prompt.Builders

  alias BeamWeaver.Prompt.{
    ChatTemplate,
    Examples,
    FewShotChatTemplate,
    Partials,
    Rendering,
    Runtime,
    StringTemplate,
    StructuredChatTemplate,
    StructuredTemplate,
    Value,
    Variables
  }

  alias BeamWeaver.Prompt.Template

  @doc "Builds a string prompt template."
  defdelegate string(template, opts \\ []), to: Builders

  @doc "Builds a chat prompt template from message template parts."
  defdelegate chat(messages, opts \\ []), to: Builders

  @doc "Builds one message template for a chat prompt."
  defdelegate message(role, template, opts \\ []), to: Builders

  @doc "Builds a placeholder for a list of messages supplied at format time."
  defdelegate placeholder(variable_name, opts \\ []), to: Builders

  @doc "Returns a prompt with partial variables pre-bound."
  defdelegate partial(prompt, partials), to: Builders

  @doc "Builds a few-shot string prompt."
  defdelegate few_shot(opts), to: Builders

  @doc "Builds a few-shot chat prompt."
  defdelegate few_shot_chat(opts), to: Builders

  @doc "Builds an image prompt part."
  defdelegate image(url, opts \\ []), to: Builders

  @doc "Builds a dictionary prompt template."
  defdelegate dict(template, opts \\ []), to: Builders

  @doc "Builds a structured-output string prompt."
  defdelegate structured(schema, template), to: Builders

  @doc "Builds a structured-output chat prompt."
  defdelegate structured_chat(messages, schema, opts \\ []), to: Builders

  @doc "Runs a structured prompt through a model and parses the result."
  defdelegate structured_chain(prompt, model, opts \\ []), to: Runtime

  def pipe_structured(%StructuredChatTemplate{} = prompt, model, opts \\ []),
    do: structured_chain(prompt, model, opts)

  @doc "Returns the variable names referenced by a prompt."
  defdelegate variables(prompt), to: Variables

  @doc "Returns a JSON schema for the prompt input."
  defdelegate input_schema(prompt), to: Variables

  def output_schema(%ChatTemplate{}), do: %{"type" => "array", "items" => %{"type" => "object"}}

  def output_schema(%FewShotChatTemplate{}),
    do: %{"type" => "array", "items" => %{"type" => "object"}}

  def output_schema(%StructuredTemplate{schema: schema}), do: schema
  def output_schema(%StructuredChatTemplate{schema: schema}), do: schema

  def output_schema(_prompt), do: %{"type" => "string"}

  def config_specs(_prompt), do: []

  defdelegate to_string(value), to: Value
  defdelegate to_messages(value), to: Value
  defdelegate value_data(value), to: Value, as: :data

  @doc "Formats a prompt with input variables and returns the rendered value."
  defdelegate format(prompt, input, opts \\ []), to: Runtime

  @doc "Formats a prompt and returns a prompt value."
  defdelegate format_prompt(prompt, input, opts \\ []), to: Runtime

  @doc "Formats a prompt asynchronously."
  defdelegate async_format(prompt, input, opts \\ []), to: Runtime

  @doc "Formats a prompt value asynchronously."
  defdelegate async_format_prompt(prompt, input, opts \\ []), to: Runtime

  def pretty_repr(prompt, opts \\ []) do
    prompt
    |> variables()
    |> Map.new(&{&1, "{" <> &1 <> "}"})
    |> then(fn dummy ->
      case format(prompt, dummy, opts) do
        {:ok, text} -> text
        {:error, %Error{} = error} -> error.message
      end
    end)
  end

  def pretty_print(prompt, opts \\ []) do
    IO.puts(pretty_repr(prompt, opts))
    :ok
  end

  def template_variables(template, template_format \\ :simple),
    do: Template.template_variables(template, template_format)

  def check_valid_template(template, input_variables, opts \\ []),
    do: Template.check_valid_template(template, input_variables, opts)

  def mustache_schema(template), do: Template.mustache_schema(template)

  defdelegate structured_data(value), to: Value

  @doc "Formats one document with a document prompt."
  defdelegate format_document(document, prompt), to: Runtime

  @doc "Formats one document with a document prompt asynchronously."
  defdelegate async_format_document(document, prompt, opts \\ []), to: Runtime

  @doc false
  defdelegate batch(prompt, inputs, opts), to: Runtime

  @doc false
  defdelegate stream(prompt, input, opts), to: Runtime

  @doc false
  defdelegate transform(prompt, input, opts), to: Runtime

  @doc false
  defdelegate merge_vars(partials, input), to: Partials

  @doc false
  defdelegate validate_input(prompt, vars), to: Partials

  @doc false
  def render(template, vars, opts \\ []), do: Template.render(template, vars, opts)

  @doc false
  defdelegate render_message_part(part, vars, opts \\ []), to: Rendering

  @doc false
  defdelegate render_message_parts(parts, vars, prompt), to: Rendering

  @doc false
  defdelegate select_examples(prompt, vars), to: Examples

  @doc false
  defdelegate validate_few_shot_sources(prompt), to: Examples

  @doc false
  defdelegate render_examples(prompt, examples, vars), to: Examples

  @doc false
  defdelegate render_chat_examples(prompt, examples, vars), to: Examples

  @doc false
  defdelegate render_optional(template, vars, prompt), to: Rendering

  def append(%ChatTemplate{} = prompt, part), do: %{prompt | messages: prompt.messages ++ [part]}

  def extend(%ChatTemplate{} = prompt, parts),
    do: %{prompt | messages: prompt.messages ++ List.wrap(parts)}

  def concat(%ChatTemplate{} = left, %ChatTemplate{} = right),
    do: %{left | messages: left.messages ++ right.messages}

  def concat(%StringTemplate{} = left, %StringTemplate{} = right) do
    if Template.equivalent_template_format?(left.template_format, right.template_format) do
      %{
        left
        | template: left.template <> right.template,
          partials: Map.merge(left.partials, right.partials),
          validate?: left.validate? or right.validate?
      }
    else
      {:error,
       Error.new(:incompatible_prompt_templates, "prompt templates use different formats", %{
         left: left.template_format,
         right: right.template_format
       })}
    end
  end

  def concat(%StringTemplate{} = left, right) when is_binary(right),
    do: %{left | template: left.template <> right}

  def slice(%ChatTemplate{} = prompt, range),
    do: %{prompt | messages: Enum.slice(prompt.messages, range)}

  def load(path, opts \\ []), do: BeamWeaver.Prompt.Loader.load(path, opts)

  def load!(path, opts \\ []), do: BeamWeaver.Prompt.Loader.load!(path, opts)

  def from_file(path, opts \\ []), do: BeamWeaver.Prompt.Loader.from_file(path, opts)

  def save(prompt, path, opts \\ []), do: BeamWeaver.Prompt.Loader.save(prompt, path, opts)

  def from_spec(spec, opts \\ []), do: BeamWeaver.Prompt.Loader.from_config(spec, opts)

  def to_spec(prompt), do: BeamWeaver.Prompt.Spec.to_spec(prompt)
end

defimpl BeamWeaver.Runnable.Spec,
  for: [
    BeamWeaver.Prompt.StringTemplate,
    BeamWeaver.Prompt.ChatTemplate,
    BeamWeaver.Prompt.FewShotTemplate,
    BeamWeaver.Prompt.FewShotChatTemplate,
    BeamWeaver.Prompt.MessageTemplate,
    BeamWeaver.Prompt.MessagesPlaceholder,
    BeamWeaver.Prompt.ImageTemplate,
    BeamWeaver.Prompt.DictTemplate,
    BeamWeaver.Prompt.StructuredTemplate,
    BeamWeaver.Prompt.StructuredChatTemplate
  ] do
  def to_spec(prompt), do: BeamWeaver.Prompt.Spec.to_spec(prompt)
end

defimpl BeamWeaver.Runnable.Introspect,
  for: [
    BeamWeaver.Prompt.StringTemplate,
    BeamWeaver.Prompt.ChatTemplate,
    BeamWeaver.Prompt.FewShotTemplate,
    BeamWeaver.Prompt.FewShotChatTemplate,
    BeamWeaver.Prompt.StructuredTemplate,
    BeamWeaver.Prompt.StructuredChatTemplate
  ] do
  def graph(prompt, _opts), do: BeamWeaver.Runnable.Graph.single(prompt)
  def input_schema(prompt), do: BeamWeaver.Prompt.input_schema(prompt)
  def output_schema(prompt), do: BeamWeaver.Prompt.output_schema(prompt)
  def config_specs(prompt), do: BeamWeaver.Prompt.config_specs(prompt)
end
