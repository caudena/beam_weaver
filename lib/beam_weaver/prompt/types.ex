defmodule BeamWeaver.Prompt.Value do
  @moduledoc "Prompt value convertible to string or chat messages."
  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message

  defstruct [:text, messages: []]

  def to_string(%__MODULE__{text: text}) when is_binary(text), do: text

  def to_string(%__MODULE__{messages: [%Message{content: [%ContentBlock.Image{url: url}]}]})
      when is_binary(url),
      do: url

  def to_string(%__MODULE__{messages: [%Message{content: [%{"image_url" => %{"url" => url}}]}]})
      when is_binary(url),
      do: url

  def to_string(%__MODULE__{messages: [%Message{content: [%{image_url: %{url: url}}]}]})
      when is_binary(url),
      do: url

  def to_string(%__MODULE__{messages: [%Message{content: [%{"url" => url}]}]})
      when is_binary(url),
      do: url

  def to_string(%__MODULE__{messages: [%Message{content: [%{url: url}]}]})
      when is_binary(url),
      do: url

  def to_string(%__MODULE__{messages: messages}) do
    Enum.map_join(messages, "\n", &Message.text/1)
  end

  def to_messages(%__MODULE__{messages: messages}) when messages != [], do: messages
  def to_messages(%__MODULE__{text: text}) when is_binary(text), do: [Message.user(text)]

  def data(%__MODULE__{text: text}), do: text
  def data(value), do: value

  def structured_data(%__MODULE__{text: text}) when is_binary(text) do
    case BeamWeaver.OutputParser.parse_json(text) do
      {:ok, data} -> data
      {:error, _error} -> text
    end
  end

  def structured_data(%__MODULE__{messages: [%Message{content: [%ContentBlock.Unknown{value: data}]}]})
      when is_map(data),
      do: data

  def structured_data(%__MODULE__{messages: [%Message{content: [data]}]}) when is_map(data),
    do: data

  def structured_data(value), do: data(value)
end

defmodule BeamWeaver.Prompt.StringTemplate do
  @moduledoc false
  @behaviour BeamWeaver.Runnable

  defstruct [:template, partials: %{}, template_format: :simple, validate?: false]

  def invoke(%__MODULE__{} = prompt, input, _opts) do
    with {:ok, vars} <- BeamWeaver.Prompt.merge_vars(prompt.partials, input),
         :ok <- BeamWeaver.Prompt.validate_input(prompt, vars),
         {:ok, text} <- BeamWeaver.Prompt.render(prompt.template, vars, prompt_opts(prompt)) do
      {:ok, %BeamWeaver.Prompt.Value{text: text}}
    end
  end

  def batch(prompt, inputs, opts), do: BeamWeaver.Prompt.batch(prompt, inputs, opts)
  def stream(prompt, input, opts), do: BeamWeaver.Prompt.stream(prompt, input, opts)
  def transform(prompt, input, opts), do: BeamWeaver.Prompt.transform(prompt, input, opts)

  defp prompt_opts(prompt), do: [template_format: prompt.template_format]
end

defmodule BeamWeaver.Prompt.MessageTemplate do
  @moduledoc false
  defstruct [:role, :template, partials: %{}, template_format: :simple]
end

defmodule BeamWeaver.Prompt.MessagesPlaceholder do
  @moduledoc false
  defstruct [:variable_name, optional: false, max_length: nil]
end

defmodule BeamWeaver.Prompt.ImageTemplate do
  @moduledoc false
  @behaviour BeamWeaver.Runnable

  defstruct [:url, :detail, partials: %{}, template_format: :simple]

  def invoke(%__MODULE__{} = template, input, _opts) do
    with {:ok, vars} <- BeamWeaver.Prompt.merge_vars(template.partials, input),
         {:ok, message} <- BeamWeaver.Prompt.render_message_part(template, vars) do
      {:ok, %BeamWeaver.Prompt.Value{messages: [message]}}
    end
  end
end

defmodule BeamWeaver.Prompt.DictTemplate do
  @moduledoc false
  @behaviour BeamWeaver.Runnable

  defstruct [:template, partials: %{}, template_format: :simple]

  def invoke(%__MODULE__{} = template, input, _opts) do
    with {:ok, vars} <- BeamWeaver.Prompt.merge_vars(template.partials, input),
         {:ok, message} <- BeamWeaver.Prompt.render_message_part(template, vars) do
      {:ok, %BeamWeaver.Prompt.Value{messages: [message]}}
    end
  end
end

defmodule BeamWeaver.Prompt.StructuredTemplate do
  @moduledoc false
  @behaviour BeamWeaver.Runnable

  defstruct [:schema, :template]

  def invoke(%__MODULE__{schema: schema, template: template}, input, opts) do
    with {:ok, value} <- BeamWeaver.Runnable.invoke(template, input, opts),
         data <- BeamWeaver.Prompt.structured_data(value),
         :ok <- BeamWeaver.OutputParser.validate_schema(schema, data) do
      {:ok, data}
    end
  end
end

defmodule BeamWeaver.Prompt.StructuredChatTemplate do
  @moduledoc false
  @behaviour BeamWeaver.Runnable

  defstruct [:schema, :prompt, structured_output_opts: []]

  def invoke(%__MODULE__{prompt: prompt}, input, opts),
    do: BeamWeaver.Runnable.invoke(prompt, input, opts)

  def batch(prompt, inputs, opts), do: BeamWeaver.Prompt.batch(prompt, inputs, opts)
  def stream(prompt, input, opts), do: BeamWeaver.Prompt.stream(prompt, input, opts)
  def transform(prompt, input, opts), do: BeamWeaver.Prompt.transform(prompt, input, opts)
end

defmodule BeamWeaver.Prompt.ChatTemplate do
  @moduledoc false
  @behaviour BeamWeaver.Runnable

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Result

  defstruct messages: [], partials: %{}, template_format: :simple

  def invoke(%__MODULE__{} = prompt, input, _opts) do
    with {:ok, vars} <- BeamWeaver.Prompt.merge_vars(prompt.partials, input) do
      prompt.messages
      |> Result.flat_traverse(&BeamWeaver.Prompt.render_message_part(&1, vars, template_format: prompt.template_format))
      |> case do
        {:ok, messages} -> {:ok, %BeamWeaver.Prompt.Value{messages: messages}}
        error -> error
      end
    end
  end

  def batch(prompt, inputs, opts), do: BeamWeaver.Prompt.batch(prompt, inputs, opts)
  def stream(prompt, input, opts), do: BeamWeaver.Prompt.stream(prompt, input, opts)
  def transform(prompt, input, opts), do: BeamWeaver.Prompt.transform(prompt, input, opts)
end

defmodule BeamWeaver.Prompt.FewShotTemplate do
  @moduledoc false
  @behaviour BeamWeaver.Runnable

  alias BeamWeaver.Core.Error

  defstruct examples: [],
            example_selector: nil,
            example_prompt: nil,
            prefix: nil,
            suffix: nil,
            example_separator: "\n\n",
            partials: %{},
            template_format: :simple

  def invoke(%__MODULE__{} = prompt, input, _opts) do
    with :ok <- BeamWeaver.Prompt.validate_few_shot_sources(prompt),
         {:ok, vars} <- BeamWeaver.Prompt.merge_vars(prompt.partials, input),
         {:ok, examples} <- BeamWeaver.Prompt.select_examples(prompt, vars),
         {:ok, rendered_examples} <- BeamWeaver.Prompt.render_examples(prompt, examples, vars),
         {:ok, prefix} <- BeamWeaver.Prompt.render_optional(prompt.prefix, vars, prompt),
         {:ok, suffix} <- BeamWeaver.Prompt.render_optional(prompt.suffix, vars, prompt) do
      text =
        [prefix | rendered_examples ++ [suffix]]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join(prompt.example_separator)

      {:ok, %BeamWeaver.Prompt.Value{text: text}}
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end
end

defmodule BeamWeaver.Prompt.FewShotChatTemplate do
  @moduledoc false
  @behaviour BeamWeaver.Runnable

  alias BeamWeaver.Core.Error

  defstruct examples: [],
            example_selector: nil,
            example_prompt: nil,
            prefix_messages: [],
            suffix_messages: [],
            partials: %{},
            template_format: :simple

  def invoke(%__MODULE__{} = prompt, input, _opts) do
    with :ok <- BeamWeaver.Prompt.validate_few_shot_sources(prompt),
         {:ok, vars} <- BeamWeaver.Prompt.merge_vars(prompt.partials, input),
         {:ok, examples} <- BeamWeaver.Prompt.select_examples(prompt, vars),
         {:ok, prefix} <-
           BeamWeaver.Prompt.render_message_parts(prompt.prefix_messages, vars, prompt),
         {:ok, example_messages} <-
           BeamWeaver.Prompt.render_chat_examples(prompt, examples, vars),
         {:ok, suffix} <-
           BeamWeaver.Prompt.render_message_parts(prompt.suffix_messages, vars, prompt) do
      {:ok, %BeamWeaver.Prompt.Value{messages: prefix ++ example_messages ++ suffix}}
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end
end
