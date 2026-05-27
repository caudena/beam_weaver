defmodule BeamWeaver.Prompt.Template do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Result
  alias BeamWeaver.Template.Mustache
  alias BeamWeaver.Template.Simple

  def render(template, vars, opts \\ [])

  def render(template, vars, opts) when is_binary(template) do
    case Keyword.get(opts, :template_format, :simple) do
      format when format in [:mustache, "mustache"] ->
        Mustache.render(template, vars, opts)

      format ->
        Simple.render(template, vars, Keyword.put(opts, :template_format, format))
    end
  end

  def render(content, vars, opts) when is_list(content) do
    Result.traverse(content, &render_content_block(&1, vars, opts))
  end

  def render(_template, _vars, _opts),
    do: {:error, Error.new(:invalid_prompt, "prompt template must be a string or content blocks")}

  def render_dict(template, vars, opts) when is_map(template) do
    rendered =
      template
      |> Result.traverse(fn {key, value} ->
        with {:ok, rendered} <- render_content_value(value, vars, opts) do
          {:ok, {key, rendered}}
        end
      end)

    case rendered do
      {:ok, entries} -> {:ok, Message.user([Map.new(entries)])}
      error -> error
    end
  end

  def render_dict(_template, _vars, _opts),
    do: {:error, Error.new(:invalid_prompt, "dict prompt template must be a map")}

  def template_variables(template, template_format \\ :simple) do
    case normalize_supported_template_format(template_format) do
      {:ok, :simple} ->
        with :ok <- Simple.validate_template(template) do
          {:ok, Simple.variables(template)}
        end

      {:ok, :mustache} ->
        {:ok, Mustache.variables(template)}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  def check_valid_template(template, input_variables, opts \\ []) do
    template_format = Keyword.get(opts, :template_format, :simple)

    with {:ok, variables} <- template_variables(template, template_format),
         :ok <- validate_template_variables(variables, input_variables) do
      case render(template, Map.new(variables, &{&1, "x"}), template_format: template_format) do
        {:ok, _rendered} -> :ok
        {:error, %Error{} = error} -> {:error, error}
      end
    end
  end

  def mustache_schema(template) do
    variables = Mustache.variables(template)

    %{
      "type" => "object",
      "properties" => Map.new(variables, &{&1, %{"type" => "any"}}),
      "required" => variables
    }
  end

  def variables_from_template(template, format) when is_binary(template) do
    case format do
      format when format in [:mustache, "mustache"] -> Mustache.variables(template)
      _format -> Simple.variables(template)
    end
  end

  def variables_from_template(content, format) when is_list(content) do
    content
    |> Enum.flat_map(fn
      value when is_binary(value) -> variables_from_template(value, format)
      value when is_map(value) -> value |> Map.values() |> variables_from_template(format)
      _other -> []
    end)
    |> Enum.uniq()
  end

  def variables_from_template(_template, _format), do: []

  def equivalent_template_format?(left, right),
    do: normalize_template_format(left) == normalize_template_format(right)

  defp render_content_block(block, vars, opts) when is_map(block) do
    block
    |> Result.traverse(fn {key, value} ->
      with {:ok, rendered} <- render_content_value(value, vars, opts) do
        {:ok, {key, rendered}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Map.new(entries)}
      error -> error
    end
  end

  defp render_content_block(block, _vars, _opts), do: {:ok, block}

  defp render_content_value(value, vars, opts) when is_binary(value),
    do: render(value, vars, opts)

  defp render_content_value(value, vars, opts) when is_map(value),
    do: render_content_block(value, vars, opts)

  defp render_content_value(values, vars, opts) when is_list(values) do
    Result.traverse(values, &render_content_value(&1, vars, opts))
  end

  defp render_content_value(value, _vars, _opts), do: {:ok, value}

  defp normalize_template_format(format) when format in [nil, :simple, "simple"], do: :simple

  defp normalize_template_format(format) when format in [:mustache, "mustache"], do: :mustache
  defp normalize_template_format(format), do: format

  defp normalize_supported_template_format(format) do
    case normalize_template_format(format) do
      :simple ->
        {:ok, :simple}

      :mustache ->
        {:ok, :mustache}

      other ->
        {:error,
         Error.new(:unsupported_template_format, "unsupported prompt template format", %{
           template_format: other,
           supported: [:simple, :mustache]
         })}
    end
  end

  defp validate_template_variables(variables, input_variables) do
    expected = input_variables |> List.wrap() |> Enum.map(&to_string/1) |> MapSet.new()
    actual = variables |> Enum.map(&to_string/1) |> MapSet.new()
    missing = MapSet.difference(actual, expected) |> MapSet.to_list()
    extra = MapSet.difference(expected, actual) |> MapSet.to_list()

    cond do
      missing != [] ->
        {:error,
         Error.new(:invalid_prompt_template, "prompt template is missing input variables", %{
           missing: missing
         })}

      extra != [] ->
        {:error,
         Error.new(:invalid_prompt_template, "prompt template declares extra input variables", %{
           extra: extra
         })}

      true ->
        :ok
    end
  end
end
