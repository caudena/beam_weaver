defmodule BeamWeaver.Prompt.Builders do
  @moduledoc false

  alias BeamWeaver.Prompt.{
    ChatTemplate,
    DictTemplate,
    FewShotChatTemplate,
    FewShotTemplate,
    ImageTemplate,
    MessagesPlaceholder,
    MessageTemplate,
    Partials,
    StringTemplate,
    StructuredChatTemplate,
    StructuredTemplate
  }

  def string(template, opts \\ []) do
    %StringTemplate{
      template: template,
      partials: Map.new(Keyword.get(opts, :partials, %{})),
      template_format: Keyword.get(opts, :template_format, :simple),
      validate?: Keyword.get(opts, :validate?, false)
    }
  end

  def chat(messages, opts \\ []) do
    %ChatTemplate{
      messages: messages,
      partials: Map.new(Keyword.get(opts, :partials, %{})),
      template_format: Keyword.get(opts, :template_format, :simple)
    }
  end

  def message(role, template, opts \\ []) do
    %MessageTemplate{
      role: role,
      template: template,
      partials: Map.new(Keyword.get(opts, :partials, %{})),
      template_format: Keyword.get(opts, :template_format, :simple)
    }
  end

  def placeholder(variable_name, opts \\ []) do
    %MessagesPlaceholder{
      variable_name: variable_name,
      optional: Keyword.get(opts, :optional, false),
      max_length: Keyword.get(opts, :max_length)
    }
  end

  def partial(prompt, partials) do
    partials = Map.new(partials)

    case prompt do
      %StringTemplate{} -> %{prompt | partials: Partials.merge(prompt.partials, partials)}
      %ChatTemplate{} -> %{prompt | partials: Partials.merge(prompt.partials, partials)}
      %FewShotTemplate{} -> %{prompt | partials: Partials.merge(prompt.partials, partials)}
      %FewShotChatTemplate{} -> %{prompt | partials: Partials.merge(prompt.partials, partials)}
      other -> other
    end
  end

  def few_shot(opts), do: struct(FewShotTemplate, few_shot_opts(opts, FewShotTemplate, :few_shot))

  def few_shot_chat(opts),
    do: struct(FewShotChatTemplate, few_shot_opts(opts, FewShotChatTemplate, :few_shot_chat))

  def image(url, opts \\ []) do
    %ImageTemplate{
      url: url,
      detail: Keyword.get(opts, :detail),
      partials: Map.new(Keyword.get(opts, :partials, %{})),
      template_format: Keyword.get(opts, :template_format, :simple)
    }
  end

  def dict(template, opts \\ []) do
    %DictTemplate{
      template: template,
      partials: Map.new(Keyword.get(opts, :partials, %{})),
      template_format: Keyword.get(opts, :template_format, :simple)
    }
  end

  def structured(schema, template), do: %StructuredTemplate{schema: schema, template: template}

  def structured_chat(messages, schema, opts \\ []) do
    {prompt_opts, output_opts} = Keyword.split(opts, [:partials, :template_format])
    output_opts = structured_output_opts(output_opts)

    %StructuredChatTemplate{
      schema: schema,
      prompt: chat(messages, prompt_opts),
      structured_output_opts: output_opts
    }
  end

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
      {keyword_key(key), value}
    end)
  end

  defp keyword_key(key) when is_atom(key), do: key

  defp keyword_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end
end
