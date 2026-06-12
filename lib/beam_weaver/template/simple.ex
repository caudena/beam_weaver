defmodule BeamWeaver.Template.Simple do
  @moduledoc false

  alias BeamWeaver.Core.Error

  @variable_pattern ~r/{([a-zA-Z_][a-zA-Z0-9_]*(?:\.[a-zA-Z_][a-zA-Z0-9_]*)*)(?:![rs])?(?::[^{}]+)?}/
  @brace_pattern ~r/{([^{}]*)}/
  @placeholder_pattern ~r/{([^{}]+)}/
  @open_brace "\0BEAM_WEAVER_OPEN_BRACE\0"
  @close_brace "\0BEAM_WEAVER_CLOSE_BRACE\0"

  def render(template, vars, opts \\ [])

  def render(template, vars, opts) when is_binary(template) and is_map(vars) do
    with :ok <- validate_format(Keyword.get(opts, :template_format, :simple)),
         :ok <- reject_nested_replacement_fields(template),
         protected <- protect_escaped_braces(template),
         :ok <- validate_placeholders(protected) do
      @placeholder_pattern
      |> Regex.scan(protected)
      |> Enum.map(fn [_match, placeholder] -> placeholder end)
      |> Enum.reduce_while({:ok, protected}, fn placeholder, {:ok, acc} ->
        {variable, format_spec} = split_placeholder(placeholder)

        case fetch_path(vars, String.split(variable, ".")) do
          {:ok, value} ->
            {:cont,
             {:ok,
              String.replace(
                acc,
                "{" <> placeholder <> "}",
                format_value(value, format_spec)
              )}}

          :error ->
            {:halt,
             {:error,
              Error.new(:prompt_missing_variable, "prompt variable is missing", %{
                variable: variable
              })}}
        end
      end)
      |> case do
        {:ok, rendered} -> {:ok, restore_escaped_braces(rendered)}
        error -> error
      end
    end
  end

  def render(_template, _vars, _opts),
    do: {:error, Error.new(:invalid_prompt, "prompt template must be a string")}

  def variables(template) when is_binary(template) do
    @variable_pattern
    |> Regex.scan(protect_escaped_braces(template))
    |> Enum.map(fn [_match, variable] -> variable end)
    |> Enum.uniq()
  end

  def variables(_template), do: []

  def validate_template(template) when is_binary(template) do
    with :ok <- reject_nested_replacement_fields(template) do
      template
      |> protect_escaped_braces()
      |> validate_placeholders()
    end
  end

  def validate_template(_template),
    do: {:error, Error.new(:invalid_prompt, "prompt template must be a string")}

  def validate_format(format)
      when format in [nil, :simple, "simple"],
      do: :ok

  def validate_format(format) do
    {:error,
     Error.new(:unsupported_template_format, "unsupported prompt template format", %{
       template_format: format,
       supported: [:simple]
     })}
  end

  defp reject_nested_replacement_fields(template) do
    if Regex.match?(~r/{[^{}:]+:[^{}]*{[^{}]+}[^{}]*}/, template) do
      {:error, Error.new(:invalid_prompt_template, "nested replacement fields are not allowed")}
    else
      :ok
    end
  end

  defp validate_placeholders(template) do
    invalid =
      @brace_pattern
      |> Regex.scan(template)
      |> Enum.map(fn [_match, placeholder] -> placeholder end)
      |> Enum.reject(fn placeholder ->
        placeholder
        |> split_placeholder()
        |> elem(0)
        |> valid_variable?()
      end)

    case invalid do
      [] ->
        :ok

      [variable | _rest] ->
        {:error,
         Error.new(:invalid_prompt_template, "prompt variable name is invalid", %{
           variable: variable
         })}
    end
  end

  defp valid_variable?(variable) do
    valid_shape? =
      Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*(?:\.[a-zA-Z_][a-zA-Z0-9_]*)*$/, variable)

    safe_segments? =
      variable
      |> String.split(".")
      |> Enum.all?(&(not String.starts_with?(&1, "__")))

    valid_shape? and safe_segments?
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

  defp stringify(nil), do: ""
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)

  defp split_placeholder(placeholder) do
    {variable_with_conversion, format_spec} =
      case String.split(placeholder, ":", parts: 2) do
        [variable, format_spec] -> {variable, format_spec}
        [variable] -> {variable, nil}
      end

    case String.split(variable_with_conversion, "!", parts: 2) do
      [variable, conversion] -> {variable, {conversion, format_spec}}
      [variable] -> {variable, {nil, format_spec}}
    end
  end

  defp format_value(value, {conversion, format_spec}) do
    value
    |> apply_conversion(conversion)
    |> apply_format_spec(format_spec)
  end

  defp apply_conversion(value, nil), do: value
  defp apply_conversion(value, "s"), do: stringify(value)
  defp apply_conversion(value, "r") when is_binary(value), do: "'" <> value <> "'"
  defp apply_conversion(value, "r"), do: inspect(value)
  defp apply_conversion(value, _conversion), do: value

  defp apply_format_spec(value, nil), do: stringify(value)

  defp apply_format_spec(value, "." <> rest) when is_number(value) do
    case Integer.parse(String.trim_trailing(rest, "f")) do
      {decimals, ""} when decimals >= 0 ->
        value
        |> Kernel.*(1.0)
        |> :erlang.float_to_binary(decimals: decimals)

      _other ->
        stringify(value)
    end
  end

  defp apply_format_spec(value, ">" <> width) do
    value
    |> stringify()
    |> String.pad_leading(parse_width(width))
  end

  defp apply_format_spec(value, <<fill::binary-size(1), "^", width::binary>>) do
    text = stringify(value)
    width = parse_width(width)
    padding = max(width - String.length(text), 0)
    left = div(padding, 2)
    right = padding - left

    String.duplicate(fill, left) <> text <> String.duplicate(fill, right)
  end

  defp apply_format_spec(value, ",") when is_integer(value), do: comma_integer(value)

  defp apply_format_spec(value, "%") when is_number(value) do
    value
    |> Kernel.*(100.0)
    |> :erlang.float_to_binary(decimals: 6)
    |> Kernel.<>("%")
  end

  defp apply_format_spec(value, _format_spec), do: stringify(value)

  defp parse_width(width) do
    case Integer.parse(width) do
      {value, ""} when value > 0 -> value
      _other -> 0
    end
  end

  defp comma_integer(value) when value < 0, do: "-" <> comma_integer(abs(value))

  defp comma_integer(value) do
    value
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map(&(&1 |> Enum.reverse() |> Enum.join()))
    |> Enum.reverse()
    |> Enum.join(",")
  end

  defp protect_escaped_braces(template) do
    template
    |> String.replace("{{", @open_brace)
    |> String.replace("}}", @close_brace)
  end

  defp restore_escaped_braces(template) do
    template
    |> String.replace(@open_brace, "{")
    |> String.replace(@close_brace, "}")
  end
end
