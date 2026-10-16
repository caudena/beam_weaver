defmodule BeamWeaver.Transport.Redactor do
  @moduledoc false

  require Record

  alias BeamWeaver.Core.Message

  @redacted "**REDACTED**"

  @secret_header_names [
    "authorization",
    "cookie",
    "set_cookie",
    "set-cookie",
    "x-api-key",
    "api-key",
    "openai-api-key",
    "proxy-authorization"
  ]

  @secret_key_parts [
    "api_key",
    "apikey",
    "private_key",
    "authorization",
    "token",
    "access_token",
    "refresh_token",
    "secret",
    "password",
    "credential"
  ]

  # The bytes that normalizing a key changes: uppercase ASCII letters, `-`,
  # and every byte of a character outside ASCII.
  @key_normalization_bytes Enum.map(Enum.concat([?A..?Z, [?-], 128..255]), &<<&1>>)

  @usage_token_keys MapSet.new([
                      "budget_tokens",
                      "max_completion_tokens",
                      "max_output_tokens",
                      "max_tokens",
                      "input_tokens",
                      "output_tokens",
                      "total_tokens",
                      "prompt_tokens",
                      "completion_tokens",
                      "cached_tokens",
                      "reasoning_tokens",
                      "input_token_details",
                      "input_tokens_details",
                      "output_token_details",
                      "output_tokens_details",
                      "prompt_tokens_details",
                      "completion_tokens_details",
                      "token_usage"
                    ])

  # Keys that every message BeamWeaver builds repeats: a tool call's fields
  # and the summary of a provider response. Whether each is a secret is
  # worked out once per node, which makes redacting a long conversation
  # about twice as fast.
  @common_atom_keys [
    :id,
    :name,
    :type,
    :args,
    :call_id,
    :provider_id,
    :thought_signature,
    :model,
    :model_name,
    :model_provider,
    :model_version,
    :provider,
    :requested_model,
    :profile_id,
    :tokenizer,
    :api,
    :provider_metadata,
    :raw,
    :tooling,
    :user,
    :hosted,
    :calls,
    :call_count,
    :results,
    :result_count,
    :usage,
    :tool_calls,
    :tool_call_count,
    :server_tool_call_count,
    :server_tool_result_count,
    :outcome,
    :remote_status,
    :turn_disposition,
    :result_completeness,
    :finish_reason,
    :stop_reason,
    :status,
    :request_id,
    :response_id,
    :run_id,
    :description
  ]

  # Every pattern in `redact_string/2` needs one of these to match.
  @secret_string_markers ["-----BEGIN", "@", "=", "Bearer", "sk-"]

  # Longer text is searched for one marker at a time, which skips text
  # faster than one search for all of them.
  @long_text_bytes 256

  # The names in `redact_secret_assignments/1`, and every byte its `\s` may
  # match.
  @secret_assignment_names ["api_key", "token", "secret", "password", "private_key", "credential"]
  @assignment_spaces [?\s, ?\t, ?\n, ?\v, ?\f, ?\r, 0x85, 0xA0]

  # Every name `redact_url_secret_params/1` matches between `?` or `&` and `=`.
  @url_secret_param_names [
    "api_key",
    "api-key",
    "apikey",
    "access_token",
    "access-token",
    "accesstoken",
    "refresh_token",
    "refresh-token",
    "refreshtoken",
    "token",
    "secret",
    "password",
    "key"
  ]

  # Compiling a search pattern costs more than most searches, so the patterns
  # are compiled once per node and kept in `:persistent_term`, with the
  # answers for the common atom keys, under a key that changes with them.
  @pattern_fields [
    :key_scan,
    :key_parts,
    :key_normalization,
    :string_markers,
    :private_key,
    :url_schemes,
    :assignment_names,
    common_atom_keys: %{}
  ]

  Record.defrecordp(:patterns, @pattern_fields)

  @pattern_sources [
    @secret_key_parts ++ @key_normalization_bytes,
    @secret_key_parts,
    @key_normalization_bytes,
    @secret_string_markers,
    "-----BEGIN",
    ["http://", "https://"],
    @secret_assignment_names
  ]
  @patterns_key {__MODULE__, :erlang.phash2({@pattern_fields, @pattern_sources, @common_atom_keys})}

  @doc """
  Redacts known secret shapes inside a term.

  The parts of `term` with nothing to redact come back as they are.
  """
  @spec redact(term()) :: term()
  def redact(term), do: redact(term, compiled_patterns())

  @doc """
  Returns the redaction marker.
  """
  @spec redacted() :: String.t()
  def redacted, do: @redacted

  defp redact(headers, patterns) when is_list(headers) and headers != [] and is_tuple(hd(headers)) do
    Enum.map(headers, fn
      {key, value} ->
        if secret_key?(key, patterns),
          do: {to_string(key), @redacted},
          else: {to_string(key), redact(value, patterns)}

      other ->
        redact(other, patterns)
    end)
  end

  defp redact(values, patterns) when is_list(values), do: redact_list(values, patterns)

  defp redact(%{__struct__: module} = value, _patterns)
       when module in [Date, DateTime, NaiveDateTime, Time] do
    value
  end

  defp redact(%Message{} = message, patterns) do
    redacted = %Message{
      message
      | content: redact(message.content, patterns),
        metadata: redact(message.metadata, patterns),
        response_metadata: redact(message.response_metadata, patterns),
        usage_metadata: redact(message.usage_metadata, patterns),
        artifacts: redact(message.artifacts, patterns),
        server_tool_calls: redact(message.server_tool_calls, patterns),
        server_tool_results: redact(message.server_tool_results, patterns),
        tool_calls: redact(message.tool_calls, patterns)
    }

    if redacted === message, do: message, else: redacted
  end

  defp redact(%{__struct__: _module} = value, patterns) do
    value
    |> Map.from_struct()
    |> redact_map(patterns)
  end

  defp redact(value, patterns) when is_map(value), do: redact_map(value, patterns)

  # Only a string that starts with `{` or `[` can hold a JSON object or array,
  # and only one with a marker can match a secret pattern, so most strings,
  # such as message text, come back as they are without a decode or a regex.
  defp redact(value, patterns) when is_binary(value) do
    cond do
      json_container?(value) -> redact_json(value, patterns)
      secret_marker?(value, patterns) and valid_utf8?(value) -> redact_string(value, patterns)
      true -> value
    end
  end

  defp redact(value, _patterns), do: value

  defp redact_list([head | tail] = list, patterns) do
    redacted_head = redact(head, patterns)
    redacted_tail = redact_list(tail, patterns)

    if redacted_head === head and redacted_tail === tail,
      do: list,
      else: [redacted_head | redacted_tail]
  end

  defp redact_list([], _patterns), do: []

  # Only the entries that change are put into the map.
  defp redact_map(map, patterns) do
    :maps.fold(
      fn key, value, redacted ->
        redacted_value = if secret_key?(key, patterns), do: @redacted, else: redact(value, patterns)
        if redacted_value === value, do: redacted, else: :maps.put(key, redacted_value, redacted)
      end,
      map,
      map
    )
  end

  defp secret_key?(key, patterns) when is_binary(key), do: secret_name?(key, patterns)

  defp secret_key?(key, patterns) when is_atom(key) and key != nil do
    case patterns(patterns, :common_atom_keys) do
      %{^key => secret?} -> secret?
      _other -> secret_name?(:erlang.atom_to_binary(key, :utf8), patterns)
    end
  end

  defp secret_key?(key, patterns), do: key |> to_string() |> secret_name?(patterns)

  # A name is a secret when, normalized (lowercase, `_` for `-`), it is a
  # secret header name or holds a secret part, and isn't a token count or
  # limit. One search finds either a secret part, which normalizing keeps,
  # or the first byte that normalizing would change; most names have
  # neither.
  defp secret_name?(name, patterns) do
    case :binary.match(name, patterns(patterns, :key_scan)) do
      :nomatch ->
        secret_header_name?(name) and not usage_or_limit_token_key?(name)

      {_position, 1} ->
        normalized = name |> String.downcase() |> String.replace("-", "_")
        secret_part? = :binary.match(normalized, patterns(patterns, :key_parts)) != :nomatch

        (secret_header_name?(normalized) or secret_part?) and not usage_or_limit_token_key?(normalized)

      {_position, _part_length} ->
        not usage_or_limit_token_key?(normalize_key(name, patterns))
    end
  end

  for name <- @secret_header_names do
    defp secret_header_name?(unquote(name)), do: true
  end

  defp secret_header_name?(_name), do: false

  defp normalize_key(key, patterns) do
    if :binary.match(key, patterns(patterns, :key_normalization)) == :nomatch,
      do: key,
      else: key |> String.downcase() |> String.replace("-", "_")
  end

  defp usage_or_limit_token_key?(normalized) do
    MapSet.member?(@usage_token_keys, normalized) or
      String.ends_with?(normalized, "_tokens") or
      String.ends_with?(normalized, "_token_count") or
      String.ends_with?(normalized, "_token_limit")
  end

  defp redact_json(value, patterns) do
    if valid_utf8?(value) do
      case BeamWeaver.JSON.decode(value) do
        {:ok, decoded} when is_map(decoded) or is_list(decoded) ->
          decoded
          |> redact(patterns)
          |> BeamWeaver.JSON.encode!(pretty: true)

        _not_json ->
          redact_string(value, patterns)
      end
    else
      value
    end
  end

  # The first byte after JSON whitespace opens an object or an array.
  defp json_container?(<<byte, rest::binary>>) when byte in [?\s, ?\t, ?\n, ?\r], do: json_container?(rest)
  defp json_container?(<<byte, _rest::binary>>), do: byte in [?{, ?[]
  defp json_container?(<<>>), do: false

  defp secret_marker?(value, patterns) when byte_size(value) < @long_text_bytes,
    do: :binary.match(value, patterns(patterns, :string_markers)) != :nomatch

  defp secret_marker?(value, patterns) do
    :binary.match(value, "=") != :nomatch or :binary.match(value, "@") != :nomatch or
      private_key_marker?(value, patterns) or contains_around?(value, "sk-", "k") or
      contains_around?(value, "Bearer", "B")
  end

  defp private_key_marker?(value, patterns),
    do: :binary.match(value, patterns(patterns, :private_key)) != :nomatch

  # Searches for one byte of `marker`, which is fast, and checks the text
  # around each one found.
  defp contains_around?(value, marker, byte) do
    {offset, 1} = :binary.match(marker, byte)
    any_byte?(value, byte, &at?(value, &1 - offset, marker))
  end

  defp any_byte?(value, byte, found?) do
    value
    |> :binary.matches(byte)
    |> Enum.any?(fn {position, 1} -> found?.(position) end)
  end

  defp at?(value, position, part) do
    position >= 0 and position + byte_size(part) <= byte_size(value) and
      binary_part(value, position, byte_size(part)) == part
  end

  # Same answer as `String.valid?/1`, faster on long, mostly ASCII text such
  # as prompts and tool descriptions.
  defp valid_utf8?(value), do: String.valid?(value, :fast_ascii)

  # Each pattern runs only when the text holds what it needs to match.
  defp redact_string(value, patterns) do
    value
    |> when_holds(&private_key_marker?(&1, patterns), &redact_private_key_blocks/1)
    |> when_holds(&url_credentials?(&1, patterns), &redact_url_credentials/1)
    |> when_holds(&url_secret_param?/1, &redact_url_secret_params/1)
    |> when_holds(&secret_assignment?(&1, patterns), &redact_secret_assignments/1)
    |> when_holds(&contains_around?(&1, "Bearer", "B"), &redact_bearer_tokens/1)
    |> when_holds(&contains_around?(&1, "sk-", "k"), &redact_sk_keys/1)
  end

  defp when_holds(value, holds?, redact) do
    if holds?.(value), do: redact.(value), else: value
  end

  # Credentials in a URL need an `@` right after the `http://` or
  # `https://` and a run of bytes other than `/`, `@` and spaces, so an email
  # address or a link alone skips the pattern. Bytes that might not count as
  # spaces to the pattern don't end the run.
  defp url_credentials?(value, patterns) do
    :binary.match(value, "@") != :nomatch and
      value
      |> :binary.matches(patterns(patterns, :url_schemes))
      |> Enum.any?(fn {position, length} -> credentials_at?(value, position + length, position + length) end)
  end

  defp credentials_at?(value, start, position) when position < byte_size(value) do
    case :binary.at(value, position) do
      ?@ -> position > start
      byte when byte in [?/, ?\s, ?\t, ?\n, ?\f, ?\r] -> false
      _byte -> credentials_at?(value, start, position + 1)
    end
  end

  defp credentials_at?(_value, _start, _position), do: false

  # The query pattern matches its names in any ASCII case, and a name is
  # made of letters, `_` and `-`, so the whole run of those bytes before an
  # `=` is the name, and the byte before the run is the `?` or `&`. An `=` in
  # prose or code skips the pattern.
  defp url_secret_param?(value), do: any_equals?(value, &url_secret_param_before?(value, &1))

  # The assignment pattern is slow on long text, so it runs only when a word
  # before an `=` (and the spaces after the word) names a secret, which every
  # match needs.
  defp secret_assignment?(value, patterns), do: any_equals?(value, &secret_name_before?(value, &1, patterns))

  defp any_equals?(value, before?), do: any_byte?(value, "=", before?)

  defp url_secret_param_before?(value, position) do
    name_start = skip_back(value, position, &url_param_name_byte?/1)

    name_start > 0 and :binary.at(value, name_start - 1) in [??, ?&] and
      String.downcase(binary_part(value, name_start, position - name_start), :ascii) in @url_secret_param_names
  end

  defp secret_name_before?(value, position, patterns) do
    word_end = skip_back(value, position, &(&1 in @assignment_spaces))
    word_start = skip_back(value, word_end, &word_byte?/1)
    word = value |> binary_part(word_start, word_end - word_start) |> String.downcase(:ascii)

    :binary.match(word, patterns(patterns, :assignment_names)) != :nomatch
  end

  defp skip_back(value, position, skip?) do
    if position > 0 and skip?.(:binary.at(value, position - 1)),
      do: skip_back(value, position - 1, skip?),
      else: position
  end

  defp word_byte?(byte), do: byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or byte == ?_
  defp url_param_name_byte?(byte), do: byte in ?a..?z or byte in ?A..?Z or byte in [?_, ?-]

  defp redact_private_key_blocks(value) do
    String.replace(
      value,
      ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----/s,
      @redacted
    )
  end

  defp redact_url_credentials(value) do
    String.replace(value, ~r/(https?:\/\/)[^\/@\s]+@/, "\\1#{@redacted}@")
  end

  defp redact_url_secret_params(value) do
    String.replace(
      value,
      ~r/([?&](?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|password|key)=)[^&\s'"]+/i,
      "\\1#{@redacted}"
    )
  end

  defp redact_secret_assignments(value) do
    String.replace(
      value,
      ~r/\b([A-Za-z0-9_]*(?:API_KEY|TOKEN|SECRET|PASSWORD|PRIVATE_KEY|CREDENTIAL)[A-Za-z0-9_]*\s*=\s*)([^\s'"&]+)/i,
      "\\1#{@redacted}"
    )
  end

  defp redact_bearer_tokens(value),
    do: String.replace(value, ~r/Bearer\s+[A-Za-z0-9._~+\/=-]+/, "Bearer #{@redacted}")

  defp redact_sk_keys(value), do: String.replace(value, ~r/sk-[A-Za-z0-9_\-]+/, @redacted)

  defp compiled_patterns do
    case :persistent_term.get(@patterns_key, nil) do
      nil ->
        [key_scan, key_parts, key_normalization, string_markers, private_key, url_schemes, assignment_names] =
          Enum.map(@pattern_sources, &:binary.compile_pattern/1)

        patterns =
          patterns(
            key_scan: key_scan,
            key_parts: key_parts,
            key_normalization: key_normalization,
            string_markers: string_markers,
            private_key: private_key,
            url_schemes: url_schemes,
            assignment_names: assignment_names
          )

        common_atom_keys =
          Map.new(@common_atom_keys, &{&1, secret_name?(Atom.to_string(&1), patterns)})

        patterns = patterns(patterns, common_atom_keys: common_atom_keys)
        :persistent_term.put(@patterns_key, patterns)
        patterns

      patterns ->
        patterns
    end
  end
end
