defmodule BeamWeaver.Core.HTML do
  @moduledoc """
  Small HTML link extraction helpers used by loaders and retrieval pipelines.
  """

  @ignored_prefixes ["javascript:", "mailto:", "#"]
  @ignored_suffixes [
    ".css",
    ".js",
    ".ico",
    ".png",
    ".jpg",
    ".jpeg",
    ".gif",
    ".svg",
    ".csv",
    ".bz2",
    ".zip",
    ".epub",
    ".webp",
    ".pdf",
    ".docx",
    ".xlsx",
    ".pptx",
    ".pptm"
  ]

  @default_link_regex ~r/href\s*=\s*["']([^"'#]*)/i

  @spec ignored_prefixes() :: [String.t()]
  def ignored_prefixes, do: @ignored_prefixes

  @spec ignored_suffixes() :: [String.t()]
  def ignored_suffixes, do: @ignored_suffixes

  @spec find_all_links(String.t(), keyword()) :: [String.t()]
  def find_all_links(raw_html, opts \\ []) when is_binary(raw_html) do
    pattern = Keyword.get(opts, :pattern, @default_link_regex)

    pattern
    |> compile_pattern()
    |> Regex.scan(raw_html)
    |> Enum.map(&link_from_match/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or ignored_link?(&1)))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec extract_sub_links(String.t(), String.t(), keyword()) :: [String.t()]
  def extract_sub_links(raw_html, url, opts \\ []) when is_binary(raw_html) and is_binary(url) do
    base_url = Keyword.get(opts, :base_url, url)
    prevent_outside? = Keyword.get(opts, :prevent_outside, true)
    exclude_prefixes = Keyword.get(opts, :exclude_prefixes, [])
    parsed_url = URI.parse(url)
    parsed_base = URI.parse(base_url)

    raw_html
    |> find_all_links(pattern: Keyword.get(opts, :pattern, @default_link_regex))
    |> Enum.map(&absolute_link(&1, url, parsed_url))
    |> Enum.reject(
      &(excluded_prefix?(&1, exclude_prefixes) or outside_base?(&1, base_url, parsed_base, prevent_outside?))
    )
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp compile_pattern(%Regex{} = pattern), do: pattern
  defp compile_pattern(pattern) when is_binary(pattern), do: Regex.compile!(pattern)

  defp link_from_match([_match, capture | _rest]), do: capture
  defp link_from_match([match]), do: match

  defp ignored_link?(link) do
    String.starts_with?(link, @ignored_prefixes) or
      Enum.any?(@ignored_suffixes, &String.ends_with?(link, &1))
  end

  defp absolute_link("//" <> _rest = link, _url, %URI{scheme: scheme}) when is_binary(scheme),
    do: "#{scheme}:#{link}"

  defp absolute_link(link, url, _parsed_url) do
    case URI.parse(link) do
      %URI{scheme: scheme} when scheme in ["http", "https"] ->
        link

      _relative ->
        URI.merge(url, link) |> URI.to_string()
    end
  end

  defp excluded_prefix?(path, prefixes), do: Enum.any?(prefixes, &String.starts_with?(path, &1))
  defp outside_base?(_path, _base_url, _parsed_base, false), do: false

  defp outside_base?(path, base_url, parsed_base, true) do
    parsed_path = URI.parse(path)
    netloc(parsed_base) != netloc(parsed_path) or not String.starts_with?(path, base_url)
  end

  defp netloc(%URI{host: nil}), do: ""
  defp netloc(%URI{host: host, port: nil}), do: host
  defp netloc(%URI{host: host, port: port}), do: "#{host}:#{port}"
end
