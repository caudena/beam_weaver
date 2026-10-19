defmodule BeamWeaver.Skill do
  @moduledoc """
  Pure parsing and argument rendering for `SKILL.md` documents.

  Parsing accepts the Agent Skills metadata fields used by BeamWeaver plus a
  small, non-authorizing subset of Claude-compatible invocation metadata. It
  intentionally rejects fields that could select execution, models, hooks, or
  background behavior. Parsing and rendering perform no filesystem access and
  grant no tools or permissions.

  `render/2` substitutes only the literal `$ARGUMENTS` placeholder in the
  Markdown body. When no placeholder exists, nonempty arguments are appended
  in a deterministic `ARGUMENTS:` section. Other dollar-prefixed forms remain
  ordinary text.
  """

  alias BeamWeaver.Core.Error

  require Logger

  @schema_version 1
  @max_document_bytes 524_288
  @max_frontmatter_bytes 16_384
  @max_description_bytes 1_024
  @max_optional_string_bytes 1_024
  @max_compatibility_bytes 500
  @max_argument_hint_bytes 512
  @max_metadata_entries 64
  @max_metadata_key_bytes 128
  @max_metadata_value_bytes 2_048
  @max_allowed_tools 64
  @max_allowed_tool_bytes 128
  @max_arguments_bytes 65_536
  @max_rendered_bytes 1_048_576

  @accepted_fields MapSet.new([
                     "name",
                     "description",
                     "license",
                     "compatibility",
                     "metadata",
                     "allowed-tools",
                     "argument-hint",
                     "disable-model-invocation",
                     "user-invocable",
                     "context"
                   ])

  @enforce_keys [:name, :description, :body]
  defstruct schema_version: @schema_version,
            name: nil,
            description: nil,
            body: nil,
            license: nil,
            compatibility: nil,
            metadata: %{},
            allowed_tools: [],
            argument_hint: nil,
            disable_model_invocation: false,
            user_invocable: true,
            context: :inline

  @type context_mode :: :inline | :fork

  @type t :: %__MODULE__{
          schema_version: 1,
          name: String.t(),
          description: String.t(),
          body: String.t(),
          license: String.t() | nil,
          compatibility: String.t() | nil,
          metadata: %{optional(String.t()) => String.t()},
          allowed_tools: [String.t()],
          argument_hint: String.t() | nil,
          disable_model_invocation: boolean(),
          user_invocable: boolean(),
          context: context_mode()
        }

  @doc """
  Parses one complete `SKILL.md` document.

  Pass `expected_name: name` when the caller knows the containing directory.
  A mismatch is rejected instead of being downgraded to advisory metadata.
  """
  @spec parse(binary(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def parse(document, opts \\ [])

  def parse(document, opts) when is_binary(document) and is_list(opts) do
    with :ok <- validate_options(opts),
         :ok <- validate_document(document),
         {:ok, yaml, body} <- split_document(document),
         :ok <- validate_frontmatter_bytes(yaml),
         :ok <- validate_frontmatter_syntax(yaml),
         :ok <- validate_unique_fields(yaml),
         {:ok, frontmatter} <- decode_frontmatter(yaml),
         :ok <- validate_fields(frontmatter),
         {:ok, name} <- required_string(frontmatter, "name", 64),
         :ok <- validate_name(name, Keyword.get(opts, :expected_name)),
         {:ok, description} <- description(frontmatter, name),
         {:ok, license} <-
           optional_string(frontmatter, "license", @max_optional_string_bytes),
         {:ok, compatibility} <-
           optional_string(frontmatter, "compatibility", @max_compatibility_bytes),
         {:ok, metadata} <- metadata(frontmatter),
         {:ok, allowed_tools} <- allowed_tools(frontmatter),
         {:ok, argument_hint} <-
           optional_string(frontmatter, "argument-hint", @max_argument_hint_bytes),
         {:ok, disable_model_invocation} <-
           optional_boolean(frontmatter, "disable-model-invocation", false),
         {:ok, user_invocable} <- optional_boolean(frontmatter, "user-invocable", true),
         {:ok, context} <- context(frontmatter) do
      {:ok,
       %__MODULE__{
         name: name,
         description: description,
         body: body,
         license: license,
         compatibility: compatibility,
         metadata: metadata,
         allowed_tools: allowed_tools,
         argument_hint: argument_hint,
         disable_model_invocation: disable_model_invocation,
         user_invocable: user_invocable,
         context: context
       }}
    end
  end

  def parse(_document, _opts),
    do: invalid("skill document and parser options must be binary and a keyword list")

  @doc """
  Renders a parsed skill body with literal invocation arguments.

  The renderer does not interpret quoting, positional arguments, environment
  variables, shell substitutions, or Claude session placeholders.
  """
  @spec render(t(), binary()) :: {:ok, binary()} | {:error, Error.t()}
  def render(%__MODULE__{body: body}, arguments)
      when is_binary(body) and is_binary(arguments) do
    with :ok <- valid_text(arguments, :arguments),
         true <- byte_size(arguments) <= @max_arguments_bytes,
         occurrences <- placeholder_count(body),
         rendered <- render_body(body, arguments, occurrences),
         true <- byte_size(rendered) <= @max_rendered_bytes do
      {:ok, rendered}
    else
      false -> invalid("skill arguments or rendered body exceed the supported size")
      {:error, %Error{}} = error -> error
    end
  end

  def render(_skill, _arguments), do: invalid("skill and arguments are invalid")

  defp validate_options(opts) do
    if Keyword.keyword?(opts),
      do: validate_keyword_options(opts),
      else: invalid("skill parser options must be a keyword list")
  end

  defp validate_keyword_options(opts) do
    keys = Keyword.keys(opts)

    cond do
      length(keys) != MapSet.size(MapSet.new(keys)) ->
        invalid("skill parser options are duplicated")

      Enum.any?(keys, &(&1 != :expected_name)) ->
        invalid("skill parser option is unsupported")

      invalid_expected_name?(Keyword.get(opts, :expected_name)) ->
        invalid("expected skill name is invalid")

      true ->
        :ok
    end
  end

  defp invalid_expected_name?(nil), do: false
  defp invalid_expected_name?(value), do: not (is_binary(value) and valid_name?(value))

  defp validate_document(document) do
    cond do
      byte_size(document) > @max_document_bytes -> invalid("skill document exceeds the byte limit")
      not String.valid?(document) -> invalid("skill document must be valid UTF-8")
      :binary.match(document, <<0>>) != :nomatch -> invalid("skill document must not contain NUL")
      true -> :ok
    end
  end

  defp split_document(<<"---\n", rest::binary>>), do: split_after_open(rest, "\n")
  defp split_document(<<"---\r\n", rest::binary>>), do: split_after_open(rest, "\r\n")
  defp split_document(_document), do: invalid("skill document must start with YAML frontmatter")

  defp split_after_open(rest, newline) do
    closing_at_eof = newline <> "---"

    case :binary.split(rest, closing_at_eof <> newline) do
      [yaml, body] ->
        {:ok, yaml, body}

      [_unterminated] ->
        if String.ends_with?(rest, closing_at_eof),
          do: {:ok, String.replace_suffix(rest, closing_at_eof, ""), ""},
          else: invalid("skill frontmatter is not terminated")
    end
  end

  defp validate_frontmatter_bytes(yaml) do
    if byte_size(yaml) <= @max_frontmatter_bytes,
      do: :ok,
      else: invalid("skill frontmatter exceeds the byte limit")
  end

  defp validate_unique_fields(yaml) do
    fields =
      Regex.scan(~r/^([a-z][a-z0-9-]*):(?:\s|$)/m, yaml, capture: :all_but_first)
      |> List.flatten()

    if length(fields) == MapSet.size(MapSet.new(fields)),
      do: :ok,
      else: invalid("skill frontmatter contains duplicate fields")
  end

  defp validate_frontmatter_syntax(yaml) do
    top_level_fields =
      yaml
      |> String.split(~r/\r?\n/u)
      |> Enum.reject(&(String.trim(&1) == "" or String.starts_with?(String.trim(&1), "#")))
      |> Enum.reject(&String.starts_with?(&1, [" ", "\t"]))

    cond do
      Enum.any?(top_level_fields, &(not Regex.match?(~r/^[a-z][a-z0-9-]*:(?:\s|$)/, &1))) ->
        invalid("skill frontmatter contains unsupported YAML syntax")

      Regex.match?(~r/(?:^|[\s\[\{,])(?:[&*][A-Za-z0-9_-]+|![^\s]+)/m, yaml) or Regex.match?(~r/^\s*<<\s*:/m, yaml) ->
        invalid("skill frontmatter contains unsupported YAML features")

      true ->
        :ok
    end
  end

  defp decode_frontmatter(yaml) do
    case BeamWeaver.YAML.decode(yaml, unique_keys: true) do
      {:ok, %{} = frontmatter} -> {:ok, frontmatter}
      {:ok, _other} -> invalid("skill frontmatter must be a map")
      {:error, :duplicate_keys} -> invalid("skill frontmatter contains duplicate fields")
      {:error, :not_one_document} -> invalid("skill frontmatter must contain exactly one YAML document")
      {:error, {:invalid, _reason}} -> invalid("skill frontmatter is invalid YAML")
    end
  end

  defp validate_fields(frontmatter) do
    fields = Map.keys(frontmatter)

    if Enum.all?(fields, &(is_binary(&1) and MapSet.member?(@accepted_fields, &1))) do
      :ok
    else
      invalid("skill frontmatter contains unsupported fields")
    end
  end

  # A description over the limit is cut to it, so a skill whose description
  # runs long still loads: the description is only the text the model picks
  # skills by.
  defp description(frontmatter, name) do
    with {:ok, description} <- required_string(frontmatter, "description", @max_frontmatter_bytes),
         do: {:ok, cut_description(description, name)}
  end

  defp cut_description(description, _name) when byte_size(description) <= @max_description_bytes,
    do: description

  defp cut_description(description, name) do
    cut = description |> binary_part(0, @max_description_bytes) |> whole_characters() |> String.trim_trailing()

    Logger.warning(
      "Skill #{inspect(name)} has a #{byte_size(description)}-byte description, over the limit of " <>
        "#{@max_description_bytes}; only its first #{byte_size(cut)} bytes are kept."
    )

    cut
  end

  # Drops the bytes of a character the cut split.
  defp whole_characters(text) do
    if String.valid?(text), do: text, else: whole_characters(binary_part(text, 0, byte_size(text) - 1))
  end

  defp required_string(frontmatter, field, maximum) do
    if is_binary(Map.get(frontmatter, field)),
      do: optional_string(frontmatter, field, maximum),
      else: invalid("skill #{field} is required", field)
  end

  defp optional_string(frontmatter, field, maximum) do
    case Map.get(frontmatter, field) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        value = String.trim(value)

        cond do
          byte_size(value) > maximum ->
            invalid("skill #{field} is #{byte_size(value)} bytes, over the limit of #{maximum}", field)

          value != "" and String.valid?(value) ->
            {:ok, value}

          true ->
            invalid("skill #{field} is invalid", field)
        end

      _other ->
        invalid("skill #{field} must be a string", field)
    end
  end

  defp optional_boolean(frontmatter, field, default) do
    case Map.get(frontmatter, field, default) do
      value when is_boolean(value) -> {:ok, value}
      _other -> invalid("skill #{field} must be a boolean", field)
    end
  end

  defp validate_name(name, expected_name) do
    cond do
      not valid_name?(name) ->
        invalid("skill name is invalid", "name")

      is_binary(expected_name) and name != expected_name ->
        invalid("skill name must match its containing directory", "name")

      true ->
        :ok
    end
  end

  defp valid_name?(name) do
    byte_size(name) in 1..64 and
      Regex.match?(~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/, name)
  end

  defp metadata(frontmatter) do
    case Map.get(frontmatter, "metadata", %{}) do
      metadata when is_map(metadata) and map_size(metadata) <= @max_metadata_entries ->
        if Enum.all?(metadata, fn {key, value} ->
             is_binary(key) and byte_size(key) in 1..@max_metadata_key_bytes and
               String.valid?(key) and is_binary(value) and
               byte_size(value) <= @max_metadata_value_bytes and String.valid?(value)
           end) do
          {:ok, metadata}
        else
          invalid("skill metadata must be a bounded string map", "metadata")
        end

      _other ->
        invalid("skill metadata must be a bounded string map", "metadata")
    end
  end

  # A string of names separated by spaces or commas, or a YAML list of names.
  defp allowed_tools(frontmatter) do
    case Map.get(frontmatter, "allowed-tools") do
      nil ->
        {:ok, []}

      value when is_binary(value) ->
        value |> String.split(~r/[\s,]+/u, trim: true) |> valid_allowed_tools()

      values when is_list(values) ->
        if Enum.all?(values, &is_binary/1),
          do: values |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> valid_allowed_tools(),
          else: invalid_allowed_tools_shape()

      _other ->
        invalid_allowed_tools_shape()
    end
  end

  defp valid_allowed_tools(values) do
    if length(values) <= @max_allowed_tools and
         length(values) == MapSet.size(MapSet.new(values)) and
         Enum.all?(values, fn tool ->
           byte_size(tool) in 1..@max_allowed_tool_bytes and String.valid?(tool)
         end) do
      {:ok, values}
    else
      invalid("skill allowed-tools is invalid", "allowed-tools")
    end
  end

  defp invalid_allowed_tools_shape,
    do: invalid("skill allowed-tools must be a string or a list of strings", "allowed-tools")

  defp context(frontmatter) do
    case Map.get(frontmatter, "context", "inline") do
      "inline" -> {:ok, :inline}
      "fork" -> {:ok, :fork}
      _other -> invalid("skill context must be inline or fork", "context")
    end
  end

  defp valid_text(value, field) do
    cond do
      not String.valid?(value) ->
        invalid("skill #{field} must be valid UTF-8", field)

      :binary.match(value, <<0>>) != :nomatch ->
        invalid("skill #{field} must not contain NUL", field)

      true ->
        :ok
    end
  end

  defp placeholder_count(body) do
    Regex.scan(~r/\$ARGUMENTS(?![A-Za-z0-9_\[\{])/u, body, return: :index)
    |> length()
  end

  defp render_body(body, arguments, occurrences) when occurrences > 0,
    do: Regex.replace(~r/\$ARGUMENTS(?![A-Za-z0-9_\[\{])/u, body, fn _match -> arguments end)

  defp render_body(body, "", 0), do: body
  defp render_body("", arguments, 0), do: "ARGUMENTS:\n" <> arguments

  defp render_body(body, arguments, 0) do
    separator = if String.ends_with?(body, "\n"), do: "\n", else: "\n\n"
    body <> separator <> "ARGUMENTS:\n" <> arguments
  end

  defp invalid(message, field \\ nil) do
    details = if is_binary(field), do: %{field: field}, else: %{}
    {:error, Error.new(:invalid_skill, message, details)}
  end
end
