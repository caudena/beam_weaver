defmodule BeamWeaver.Prompt.Examples do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.ExampleSelector
  alias BeamWeaver.Result

  alias BeamWeaver.Prompt.{
    ChatTemplate,
    Partials,
    Runtime,
    StringTemplate,
    Value,
    Variables
  }

  def select_examples(%{example_selector: nil, examples: examples}, _vars),
    do: {:ok, examples || []}

  def select_examples(%{example_selector: selector}, vars) do
    ExampleSelector.select(selector, vars)
  end

  def validate_few_shot_sources(%{example_selector: nil}), do: :ok

  def validate_few_shot_sources(%{examples: examples, example_selector: selector})
      when not is_nil(selector) and examples in [nil, []],
      do: :ok

  def validate_few_shot_sources(%{examples: examples, example_selector: selector})
      when not is_nil(selector) do
    {:error,
     Error.new(
       :invalid_prompt,
       "few-shot prompts cannot define examples and an example selector",
       %{
         examples: length(List.wrap(examples))
       }
     )}
  end

  def render_examples(prompt, examples, vars) do
    example_prompt = prompt.example_prompt || %StringTemplate{template: "{input}"}

    Result.traverse(examples, fn example ->
      with {:ok, value} <-
             Runtime.format_prompt(
               example_prompt,
               example_input(example_prompt, example, vars)
             ) do
        {:ok, Value.to_string(value)}
      end
    end)
  end

  def render_chat_examples(prompt, examples, vars) do
    example_prompt = prompt.example_prompt || %ChatTemplate{messages: [{:user, "{input}"}]}

    Result.flat_traverse(examples, fn example ->
      with {:ok, value} <- Runtime.format_prompt(example_prompt, example_input(example_prompt, example, vars)) do
        {:ok, Value.to_messages(value)}
      end
    end)
  end

  defp example_input(_example_prompt, example, _vars) when not is_map(example) do
    %{input: example}
  end

  defp example_input(example_prompt, example, _vars) do
    example_prompt
    |> Variables.variables()
    |> Enum.reduce(%{}, fn variable, acc ->
      case Partials.fetch_var(example, variable) do
        {:ok, value} -> Map.put(acc, variable, value)
        :error -> acc
      end
    end)
  end
end
