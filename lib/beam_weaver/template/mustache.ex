defmodule BeamWeaver.Template.Mustache do
  @moduledoc false

  alias BeamWeaver.Core.Error

  def render(template, vars, opts \\ [])

  def render(template, vars, _opts) when is_binary(template) and is_map(vars) do
    with {:ok, nodes} <- parse(template) do
      render_nodes(nodes, [vars])
    end
  end

  def render(_template, _vars, _opts),
    do: {:error, Error.new(:invalid_prompt, "prompt template must be a string")}

  def variables(template) when is_binary(template) do
    case parse(template) do
      {:ok, nodes} -> nodes |> collect_variables(false) |> Enum.uniq()
      {:error, %Error{}} -> []
    end
  end

  def variables(_template), do: []

  defp parse(template) do
    with {:ok, nodes, position} <- parse_until(template, 0, nil) do
      if position == byte_size(template) do
        {:ok, nodes}
      else
        {:error, Error.new(:invalid_prompt_template, "mustache template is invalid")}
      end
    end
  end

  defp parse_until(template, position, closing_name) do
    do_parse_until(template, position, closing_name, [])
  end

  defp do_parse_until(template, position, closing_name, acc) do
    size = byte_size(template)

    case next_tag(template, position) do
      nil ->
        acc = add_text(acc, binary_part(template, position, size - position))

        if closing_name do
          {:error,
           Error.new(:invalid_prompt_template, "mustache section is missing a closing tag", %{
             section: closing_name
           })}
        else
          {:ok, Enum.reverse(acc), size}
        end

      {:ok, start, after_tag, :triple, tag} ->
        acc = add_text(acc, binary_part(template, position, start - position))

        with {:ok, variable} <- variable_name(tag) do
          do_parse_until(template, after_tag, closing_name, [{:var, variable} | acc])
        end

      {:ok, start, after_tag, :double, tag} ->
        acc = add_text(acc, binary_part(template, position, start - position))

        case parse_tag(tag) do
          {:ok, {:close, name}} ->
            cond do
              is_nil(closing_name) ->
                {:error,
                 Error.new(:invalid_prompt_template, "mustache closing tag has no opener", %{
                   section: name
                 })}

              name != closing_name ->
                {:error,
                 Error.new(:invalid_prompt_template, "mustache closing tag is mismatched", %{
                   expected: closing_name,
                   actual: name
                 })}

              true ->
                {:ok, Enum.reverse(acc), after_tag}
            end

          {:ok, {:section, name}} ->
            with {:ok, children, after_section} <- parse_until(template, after_tag, name) do
              do_parse_until(template, after_section, closing_name, [
                {:section, name, children} | acc
              ])
            end

          {:ok, {:inverted, name}} ->
            with {:ok, children, after_section} <- parse_until(template, after_tag, name) do
              do_parse_until(template, after_section, closing_name, [
                {:inverted, name, children} | acc
              ])
            end

          {:ok, {:var, name}} ->
            do_parse_until(template, after_tag, closing_name, [{:var, name} | acc])

          {:ok, :comment} ->
            do_parse_until(template, after_tag, closing_name, acc)

          {:error, %Error{} = error} ->
            {:error, error}
        end
    end
  end

  defp next_tag(template, position) do
    size = byte_size(template)

    case :binary.match(template, "{{", scope: {position, size - position}) do
      :nomatch ->
        nil

      {start, 2} ->
        triple? = start + 2 < size and binary_part(template, start, 3) == "{{{"
        terminator = if triple?, do: "}}}", else: "}}"
        content_start = start + if(triple?, do: 3, else: 2)

        case :binary.match(template, terminator, scope: {content_start, size - content_start}) do
          :nomatch ->
            {:ok, start, size, if(triple?, do: :triple, else: :double), ""}

          {stop, terminator_size} ->
            tag = binary_part(template, content_start, stop - content_start)
            {:ok, start, stop + terminator_size, if(triple?, do: :triple, else: :double), tag}
        end
    end
  end

  defp parse_tag(tag) do
    tag = String.trim(tag)

    cond do
      tag == "" ->
        {:error, Error.new(:invalid_prompt_template, "mustache tag cannot be empty")}

      String.starts_with?(tag, "!") ->
        {:ok, :comment}

      String.starts_with?(tag, "#") ->
        with {:ok, name} <- variable_name(String.trim_leading(tag, "#")) do
          {:ok, {:section, name}}
        end

      String.starts_with?(tag, "^") ->
        with {:ok, name} <- variable_name(String.trim_leading(tag, "^")) do
          {:ok, {:inverted, name}}
        end

      String.starts_with?(tag, "/") ->
        with {:ok, name} <- variable_name(String.trim_leading(tag, "/")) do
          {:ok, {:close, name}}
        end

      String.starts_with?(tag, "&") ->
        with {:ok, name} <- variable_name(String.trim_leading(tag, "&")) do
          {:ok, {:var, name}}
        end

      true ->
        with {:ok, name} <- variable_name(tag) do
          {:ok, {:var, name}}
        end
    end
  end

  defp variable_name(tag) do
    name = String.trim(tag)

    if valid_variable?(name) do
      {:ok, name}
    else
      {:error,
       Error.new(:invalid_prompt_template, "mustache variable name is invalid", %{
         variable: name
       })}
    end
  end

  defp valid_variable?("."), do: true

  defp valid_variable?(name) do
    Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*(?:\.[a-zA-Z_][a-zA-Z0-9_]*)*$/, name) and
      name
      |> String.split(".")
      |> Enum.all?(&(not String.starts_with?(&1, "__")))
  end

  defp add_text(acc, ""), do: acc
  defp add_text(acc, text), do: [{:text, text} | acc]

  defp render_nodes(nodes, stack) do
    Enum.reduce_while(nodes, {:ok, ""}, fn node, {:ok, acc} ->
      case render_node(node, stack) do
        {:ok, rendered} -> {:cont, {:ok, acc <> rendered}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp render_node({:text, text}, _stack), do: {:ok, text}

  defp render_node({:var, name}, stack) do
    case fetch_value(stack, name) do
      {:ok, value} -> {:ok, stringify(value)}
      :error -> {:ok, ""}
    end
  end

  defp render_node({:section, name, children}, stack) do
    case fetch_value(stack, name) do
      {:ok, value} -> render_section(value, children, stack)
      :error -> {:ok, ""}
    end
  end

  defp render_node({:inverted, name, children}, stack) do
    case fetch_value(stack, name) do
      {:ok, value} ->
        if truthy?(value), do: {:ok, ""}, else: render_nodes(children, stack)

      :error ->
        render_nodes(children, stack)
    end
  end

  defp render_section(values, children, stack) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, ""}, fn value, {:ok, acc} ->
      case render_nodes(children, [value | stack]) do
        {:ok, rendered} -> {:cont, {:ok, acc <> rendered}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp render_section(value, children, stack) do
    if truthy?(value) do
      render_nodes(children, [value | stack])
    else
      {:ok, ""}
    end
  end

  defp fetch_value([current | _stack], "."), do: {:ok, current}

  defp fetch_value(stack, name) do
    [head | rest] = String.split(name, ".")

    Enum.find_value(stack, :error, fn context ->
      with {:ok, value} <- fetch_segment(context, head),
           {:ok, value} <- fetch_path(value, rest) do
        {:ok, value}
      else
        :error -> nil
      end
    end)
  end

  defp fetch_path(value, []), do: {:ok, value}

  defp fetch_path(value, [segment | rest]) do
    with {:ok, nested} <- fetch_segment(value, segment) do
      fetch_path(nested, rest)
    end
  end

  defp fetch_segment(%{__struct__: _module} = struct, segment) do
    struct
    |> Map.from_struct()
    |> fetch_segment(segment)
  end

  defp fetch_segment(map, segment) when is_map(map) do
    Enum.find_value(map, :error, fn {key, value} ->
      if to_string(key) == segment, do: {:ok, value}, else: nil
    end)
  end

  defp fetch_segment(_value, _segment), do: :error

  defp truthy?(nil), do: false
  defp truthy?(false), do: false
  defp truthy?([]), do: false
  defp truthy?(map) when is_map(map), do: map_size(map) > 0
  defp truthy?(_value), do: true

  defp stringify(nil), do: ""
  defp stringify([]), do: ""
  defp stringify(map) when is_map(map) and map_size(map) == 0, do: ""
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)

  defp collect_variables(nodes, inside_section?) do
    Enum.flat_map(nodes, fn
      {:var, "."} ->
        []

      {:var, name} ->
        if inside_section?, do: [], else: [top_level(name)]

      {:section, name, children} ->
        [top_level(name) | collect_variables(children, true)]

      {:inverted, name, children} ->
        [top_level(name) | collect_variables(children, true)]

      {:text, _text} ->
        []
    end)
  end

  defp top_level(name), do: name |> String.split(".") |> hd()
end
