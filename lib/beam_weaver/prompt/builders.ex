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
      %StringTemplate{} -> %{prompt | partials: Map.merge(prompt.partials, partials)}
      %ChatTemplate{} -> %{prompt | partials: Map.merge(prompt.partials, partials)}
      %FewShotTemplate{} -> %{prompt | partials: Map.merge(prompt.partials, partials)}
      %FewShotChatTemplate{} -> %{prompt | partials: Map.merge(prompt.partials, partials)}
      other -> other
    end
  end

  def few_shot(opts), do: struct(FewShotTemplate, normalize_few_shot_opts(opts))

  def few_shot_chat(opts), do: struct(FewShotChatTemplate, normalize_few_shot_opts(opts))

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

  defp normalize_few_shot_opts(opts) do
    opts
    |> Keyword.update(:partials, %{}, &Map.new/1)
    |> Keyword.put_new(:template_format, :simple)
  end

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
