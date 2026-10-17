defmodule BeamWeaver.Prompt do
  @moduledoc """
  Runnable-compatible prompt primitives.
  """

  import Kernel, except: [to_string: 1]

  alias BeamWeaver.Core.Error

  alias BeamWeaver.Prompt.{
    ChatTemplate,
    DictTemplate,
    FewShotChatTemplate,
    FewShotTemplate,
    ImageTemplate,
    MessagesPlaceholder,
    MessageTemplate,
    Partials,
    Runtime,
    StringTemplate,
    StructuredChatTemplate,
    StructuredTemplate,
    Template,
    Value,
    Variables
  }

  @doc "Builds a string prompt template."
  def string(template, opts \\ []) do
    %StringTemplate{
      template: template,
      partials: Map.new(Keyword.get(opts, :partials, %{})),
      template_format: Keyword.get(opts, :template_format, :simple),
      validate?: Keyword.get(opts, :validate?, false)
    }
  end

  @doc "Builds a chat prompt template from message template parts."
  def chat(messages, opts \\ []) do
    %ChatTemplate{
      messages: messages,
      partials: Map.new(Keyword.get(opts, :partials, %{})),
      template_format: Keyword.get(opts, :template_format, :simple)
    }
  end

  @doc "Builds one message template for a chat prompt."
  def message(role, template, opts \\ []) do
    %MessageTemplate{
      role: role,
      template: template,
      partials: Map.new(Keyword.get(opts, :partials, %{})),
      template_format: Keyword.get(opts, :template_format, :simple)
    }
  end

  @doc "Builds a placeholder for a list of messages supplied at format time."
  def placeholder(variable_name, opts \\ []) do
    %MessagesPlaceholder{
      variable_name: variable_name,
      optional: Keyword.get(opts, :optional, false),
      max_length: Keyword.get(opts, :max_length)
    }
  end

  @doc "Returns a prompt with partial variables pre-bound."
  def partial(prompt, partials) do
    partials = Map.new(partials)

    case prompt do
      %type{} when type in [StringTemplate, ChatTemplate, FewShotTemplate, FewShotChatTemplate] ->
        %{prompt | partials: Partials.merge(prompt.partials, partials)}

      other ->
        other
    end
  end

  @doc "Builds a few-shot string prompt."
  def few_shot(opts), do: struct(FewShotTemplate, few_shot_opts(opts, FewShotTemplate, :few_shot))

  @doc "Builds a few-shot chat prompt."
  def few_shot_chat(opts),
    do: struct(FewShotChatTemplate, few_shot_opts(opts, FewShotChatTemplate, :few_shot_chat))

  @doc "Builds an image prompt part."
  def image(url, opts \\ []) do
    %ImageTemplate{
      url: url,
      detail: Keyword.get(opts, :detail),
      partials: Map.new(Keyword.get(opts, :partials, %{})),
      template_format: Keyword.get(opts, :template_format, :simple)
    }
  end

  @doc "Builds a dictionary prompt template."
  def dict(template, opts \\ []) do
    %DictTemplate{
      template: template,
      partials: Map.new(Keyword.get(opts, :partials, %{})),
      template_format: Keyword.get(opts, :template_format, :simple)
    }
  end

  @doc "Builds a structured-output string prompt."
  def structured(schema, template), do: %StructuredTemplate{schema: schema, template: template}

  @doc "Builds a structured-output chat prompt."
  def structured_chat(messages, schema, opts \\ []) do
    {prompt_opts, output_opts} = Keyword.split(opts, [:partials, :template_format])

    %StructuredChatTemplate{
      schema: schema,
      prompt: chat(messages, prompt_opts),
      structured_output_opts: structured_output_opts(output_opts)
    }
  end

  @doc "Runs a structured prompt through a model and parses the result."
  defdelegate structured_chain(prompt, model, opts \\ []), to: Runtime

  def pipe_structured(%StructuredChatTemplate{} = prompt, model, opts \\ []),
    do: structured_chain(prompt, model, opts)

  @doc "Returns the variable names referenced by a prompt."
  defdelegate variables(prompt), to: Variables

  @doc "Returns a JSON schema for the prompt input."
  defdelegate input_schema(prompt), to: Variables

  def output_schema(%type{}) when type in [ChatTemplate, FewShotChatTemplate],
    do: %{"type" => "array", "items" => %{"type" => "object"}}

  def output_schema(%StructuredTemplate{schema: schema}), do: schema
  def output_schema(%StructuredChatTemplate{schema: schema}), do: schema

  def output_schema(_prompt), do: %{"type" => "string"}

  defdelegate to_string(value), to: Value
  defdelegate to_messages(value), to: Value
  defdelegate value_data(value), to: Value, as: :data

  @doc "Formats a prompt with input variables and returns the rendered value."
  defdelegate format(prompt, input, opts \\ []), to: Runtime

  @doc "Formats a prompt and returns a prompt value."
  defdelegate format_prompt(prompt, input, opts \\ []), to: Runtime

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

  def load(path, _opts \\ []), do: BeamWeaver.Prompt.Loader.load(path)

  def load!(path, _opts \\ []), do: BeamWeaver.Prompt.Loader.load!(path)

  def from_file(path, opts \\ []), do: BeamWeaver.Prompt.Loader.from_file(path, opts)

  def save(prompt, path, _opts \\ []), do: BeamWeaver.Prompt.Loader.save(prompt, path)

  def from_spec(spec, _opts \\ []), do: BeamWeaver.Prompt.Loader.from_config(spec)

  def to_spec(prompt), do: BeamWeaver.Prompt.Spec.to_spec(prompt)

  # An option the template doesn't have raises instead of being dropped.
  defp few_shot_opts(opts, template, builder) do
    allowed = template |> struct() |> Map.from_struct() |> Map.keys()

    case Keyword.keys(opts) -- allowed do
      [] ->
        opts
        |> Keyword.update(:partials, %{}, &Map.new/1)
        |> Keyword.put_new(:template_format, :simple)

      unknown ->
        raise ArgumentError,
              "unknown options #{inspect(unknown)} for Prompt.#{builder}/1" <> few_shot_hint(builder, unknown)
    end
  end

  defp few_shot_hint(:few_shot_chat, unknown) do
    if Enum.any?(unknown, &(&1 in [:prefix, :suffix])),
      do: "; a chat prompt takes lists of messages as prefix_messages: and suffix_messages:",
      else: ""
  end

  defp few_shot_hint(_builder, _unknown), do: ""

  defp structured_output_opts(opts) do
    explicit =
      opts
      |> Keyword.get(:structured_output_opts, [])
      |> normalize_keyword_opts()

    opts
    |> Keyword.delete(:structured_output_opts)
    |> then(&Keyword.merge(explicit, &1))
  end

  defp normalize_keyword_opts(nil), do: []
  defp normalize_keyword_opts(opts) when is_list(opts), do: opts

  defp normalize_keyword_opts(opts) when is_map(opts) do
    Enum.into(opts, [], fn {key, value} ->
      {BeamWeaver.MapAccess.existing_atom_key(key), value}
    end)
  end
end
