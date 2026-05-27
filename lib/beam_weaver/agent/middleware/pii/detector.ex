defmodule BeamWeaver.Agent.Middleware.PII.Detector do
  @moduledoc false

  @builtin_types ["email", "credit_card", "ip", "mac_address", "url"]

  def builtin_types, do: @builtin_types

  def detect(text, middleware) do
    built_in =
      middleware.detectors
      |> Enum.flat_map(&detect_builtin(&1, text))

    configured =
      case middleware.detector do
        nil ->
          []

        detector ->
          detect_custom_detector(
            detector,
            middleware.pii_type || detector_type(List.first(middleware.detectors)),
            text
          )
      end

    custom =
      middleware.custom
      |> Enum.flat_map(fn
        fun when is_function(fun, 1) ->
          detect_custom_detector(fun, middleware.pii_type, text)

        {module, function, args} ->
          apply(module, function, [text | args]) |> normalize_matches(middleware.pii_type)
      end)

    (built_in ++ configured ++ custom)
    |> Enum.uniq_by(fn match -> {match.start, match.end, match.value, match.type} end)
    |> Enum.sort_by(& &1.start)
  end

  def detect_email(content) when is_binary(content) do
    ~r/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/
    |> regex_matches(content, "email")
  end

  def detect_credit_card(content) when is_binary(content) do
    ~r/\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b/
    |> regex_matches(content, "credit_card")
    |> Enum.filter(fn match -> luhn?(match.value) end)
  end

  def detect_ip(content) when is_binary(content) do
    ~r/\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b/
    |> regex_matches(content, "ip")
    |> Enum.filter(fn match -> valid_ipv4?(match.value) end)
  end

  def detect_mac_address(content) when is_binary(content) do
    ~r/\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b/
    |> regex_matches(content, "mac_address")
  end

  def detect_url(content) when is_binary(content) do
    scheme_matches =
      ~r/https?:\/\/[^\s<>"{}|\\^`\[\]]+/
      |> regex_matches(content, "url")
      |> Enum.filter(&valid_url_with_scheme?/1)

    bare_matches =
      ~r/\b(?:www\.)?[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+(?:\/[^\s]*)?/
      |> regex_matches(content, "url")
      |> Enum.reject(&overlaps?(&1, scheme_matches))
      |> Enum.filter(fn match ->
        (String.starts_with?(match.value, "www.") or String.contains?(match.value, "/")) and
          valid_bare_url?(match.value)
      end)

    scheme_matches ++ bare_matches
  end

  def normalize_matches(matches, pii_type) do
    matches
    |> List.wrap()
    |> Enum.map(&normalize_match(&1, pii_type))
    |> Enum.reject(&is_nil/1)
  end

  def normalize_match(%{} = match, pii_type) do
    start = Map.get(match, :start, Map.get(match, "start"))
    end_offset = Map.get(match, :end, Map.get(match, "end"))

    value =
      Map.get(
        match,
        :value,
        Map.get(match, "value", Map.get(match, :text, Map.get(match, "text", "")))
      )

    type = Map.get(match, :type, Map.get(match, "type", pii_type || "custom"))

    if is_integer(start) and is_integer(end_offset) and is_binary(value) do
      %{type: to_string(type), value: value, start: start, end: end_offset}
    end
  end

  def normalize_match(_match, _pii_type), do: nil

  def normalize_detector(:mac), do: :mac_address
  def normalize_detector("mac"), do: :mac_address
  def normalize_detector("mac_address"), do: :mac_address

  def normalize_detector(detector)
      when detector in [:email, :credit_card, :ip, :mac_address, :url],
      do: detector

  def normalize_detector(detector) when is_binary(detector) do
    detector
    |> String.to_existing_atom()
    |> normalize_detector()
  rescue
    ArgumentError -> :custom
  end

  def normalize_detector(_detector), do: :custom

  def detector_type(:mac_address), do: "mac_address"
  def detector_type(:custom), do: "custom"
  def detector_type(type), do: to_string(type)

  def normalize_type(nil), do: nil
  def normalize_type(:mac), do: "mac_address"
  def normalize_type("mac"), do: "mac_address"
  def normalize_type(type), do: to_string(type)

  def validate_detector_config!(nil, _detector, _detectors), do: :ok

  def validate_detector_config!(pii_type, nil, _detectors) do
    unless normalize_type(pii_type) in @builtin_types do
      raise ArgumentError,
            "Unknown PII type: #{pii_type}. Must be one of #{inspect(@builtin_types)} or provide a custom detector."
    end
  end

  def validate_detector_config!(_pii_type, _detector, _detectors), do: :ok

  defp detect_builtin(:email, text), do: detect_email(text)
  defp detect_builtin(:credit_card, text), do: detect_credit_card(text)
  defp detect_builtin(:ip, text), do: detect_ip(text)
  defp detect_builtin(:mac_address, text), do: detect_mac_address(text)
  defp detect_builtin(:url, text), do: detect_url(text)
  defp detect_builtin(_detector, _text), do: []

  defp detect_custom_detector(regex, pii_type, text) when is_binary(regex) do
    regex
    |> Regex.compile!()
    |> regex_matches(text, pii_type || "custom")
  end

  defp detect_custom_detector(fun, pii_type, text) when is_function(fun, 1) do
    fun.(text) |> normalize_matches(pii_type)
  end

  defp regex_matches(regex, text, type) do
    regex
    |> Regex.scan(text, return: :index)
    |> Enum.map(fn [{start, length} | _captures] ->
      %{
        type: to_string(type),
        value: binary_part(text, start, length),
        start: start,
        end: start + length
      }
    end)
  end

  defp luhn?(value) do
    digits =
      value
      |> String.replace(~r/\D/, "")
      |> String.graphemes()
      |> Enum.map(&String.to_integer/1)

    digits != [] and rem(luhn_sum(Enum.reverse(digits), 0, 0), 10) == 0
  end

  defp valid_ipv4?(value) do
    value
    |> String.split(".")
    |> Enum.all?(fn octet ->
      case Integer.parse(octet) do
        {number, ""} -> number >= 0 and number <= 255
        _other -> false
      end
    end)
  end

  defp luhn_sum([], _index, sum), do: sum

  defp luhn_sum([digit | rest], index, sum) do
    digit =
      if rem(index, 2) == 1 do
        doubled = digit * 2
        if doubled > 9, do: doubled - 9, else: doubled
      else
        digit
      end

    luhn_sum(rest, index + 1, sum + digit)
  end

  defp valid_url_with_scheme?(%{value: value}) do
    uri = URI.parse(value)
    uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != ""
  end

  defp valid_bare_url?(value) do
    uri = URI.parse("http://" <> value)
    is_binary(uri.host) and String.contains?(uri.host, ".")
  end

  defp overlaps?(match, matches) do
    Enum.any?(matches, fn other ->
      (other.start <= match.start and match.start < other.end) or
        (other.start < match.end and match.end <= other.end)
    end)
  end
end
