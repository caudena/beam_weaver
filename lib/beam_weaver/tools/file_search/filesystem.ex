defmodule BeamWeaver.Tools.FileSearch.Filesystem do
  @moduledoc false

  alias BeamWeaver.Core.Document
  alias BeamWeaver.Core.Error

  def search(tool, input) do
    with {:ok, max_results} <- max_results(tool, input),
         {:ok, include} <- compile_patterns(tool.include),
         {:ok, exclude} <- compile_patterns(tool.exclude),
         {:ok, matcher} <- query_matcher(tool, input),
         {:ok, output_mode} <- output_mode(tool, input),
         {:ok, files} <- filesystem_files(tool, include, exclude) do
      results =
        files
        |> sort_files(tool.sort)
        |> Stream.map(&match_file(&1, matcher, output_mode, tool))
        |> Stream.reject(&is_nil/1)
        |> Enum.take(max_results)

      {:ok, results}
    end
  end

  defp filesystem_files(%{roots: roots} = tool, include, exclude) do
    case Enum.reject(roots, &File.dir?/1) do
      [] ->
        {:ok,
         roots
         |> Enum.flat_map(&walk_root(&1, tool))
         |> Enum.filter(&included?(&1, include, exclude))}

      missing ->
        {:error,
         Error.new(:file_search_root_not_found, "file search root does not exist", %{
           roots: missing
         })}
    end
  end

  defp walk_root(root, tool) do
    root
    |> walk_dir(root, tool)
    |> Enum.sort_by(& &1.relative_path)
  end

  defp walk_dir(dir, root, tool) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.flat_map(names, fn name ->
          path = Path.join(dir, name)
          relative_path = Path.relative_to(path, root)

          cond do
            not tool.include_hidden? and hidden_path?(relative_path) ->
              []

            regular_file?(path) ->
              [%{root: root, path: path, relative_path: relative_path}]

            directory?(path) ->
              walk_dir(path, root, tool)

            true ->
              []
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  defp regular_file?(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} -> true
      _other -> false
    end
  end

  defp directory?(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> true
      _other -> false
    end
  end

  defp hidden_path?(relative_path) do
    relative_path
    |> Path.split()
    |> Enum.any?(&String.starts_with?(&1, "."))
  end

  defp included?(file, include, exclude) do
    Enum.any?(include, &Regex.match?(&1, file.relative_path)) and
      not Enum.any?(exclude, &Regex.match?(&1, file.relative_path))
  end

  defp sort_files(files, :mtime_desc),
    do: Enum.sort_by(files, &mtime(&1.path), :desc)

  defp sort_files(files, "mtime_desc"),
    do: sort_files(files, :mtime_desc)

  defp sort_files(files, _sort),
    do: Enum.sort_by(files, & &1.relative_path)

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime
      _other -> 0
    end
  end

  defp match_file(file, matcher, output_mode, tool) do
    case read_searchable_file(file.path, tool.max_file_bytes) do
      {:ok, content} ->
        file_document(file, content, matcher, output_mode, tool)

      :skip ->
        nil

      {:error, _reason} ->
        nil
    end
  end

  defp read_searchable_file(path, max_file_bytes) do
    case File.stat(path) do
      {:ok, %{size: size}} when is_integer(max_file_bytes) and size > max_file_bytes ->
        :skip

      {:ok, _stat} ->
        File.read(path)

      {:error, _reason} = error ->
        error
    end
  end

  defp file_document(file, content, matcher, :count, _tool) do
    line_count = matching_line_count(content, matcher)
    path_match? = matches?(matcher, file.relative_path)
    count = line_count + if path_match?, do: 1, else: 0

    if count > 0 do
      document =
        Document.new!(Integer.to_string(count),
          metadata:
            file_metadata(file, %{
              match_count: count,
              line_match_count: line_count,
              path_match?: path_match?,
              output_mode: "count"
            })
        )

      Map.from_struct(document)
    end
  end

  defp file_document(file, content, matcher, _output_mode, tool) do
    if matches?(matcher, content) or matches?(matcher, file.relative_path) do
      document =
        Document.new!(
          snippet(content, matcher, tool.snippet_bytes),
          metadata: file_metadata(file)
        )

      Map.from_struct(document)
    end
  end

  defp file_metadata(file, extra \\ %{}) do
    Map.merge(
      %{
        path: file.path,
        relative_path: file.relative_path,
        root: file.root,
        source: "filesystem"
      },
      extra
    )
  end

  defp trim_file(content, max_bytes) when byte_size(content) <= max_bytes, do: content
  defp trim_file(content, max_bytes), do: binary_part(content, 0, max_bytes)

  defp snippet(content, {:literal, regex}, max_bytes) do
    case Regex.run(regex, content, return: :index) do
      {index, length} ->
        snippet_at(content, index, length, max_bytes)

      [{index, length} | _captures] ->
        snippet_at(content, index, length, max_bytes)

      _nomatch ->
        trim_file(content, max_bytes)
    end
  end

  defp snippet(content, {:regex, regex}, max_bytes) do
    case Regex.run(regex, content, return: :index) do
      [{index, length} | _captures] -> snippet_at(content, index, length, max_bytes)
      _other -> trim_file(content, max_bytes)
    end
  end

  defp snippet_at(content, index, length, max_bytes) do
    context_bytes = max(max_bytes - length, 0)
    before = div(context_bytes, 3)
    after_bytes = context_bytes - before
    start = max(index - before, 0)
    stop = min(index + length + after_bytes, byte_size(content))
    valid_binary_part(content, start, stop)
  end

  defp valid_binary_part(content, start, stop) do
    start = next_utf8_boundary(content, start)
    stop = previous_utf8_boundary(content, stop)

    if stop > start, do: binary_part(content, start, stop - start), else: ""
  end

  defp next_utf8_boundary(_content, index) when index <= 0, do: 0

  defp next_utf8_boundary(content, index) when index >= byte_size(content),
    do: byte_size(content)

  defp next_utf8_boundary(content, index) do
    if utf8_boundary?(content, index), do: index, else: next_utf8_boundary(content, index + 1)
  end

  defp previous_utf8_boundary(_content, index) when index <= 0, do: 0

  defp previous_utf8_boundary(content, index) when index >= byte_size(content),
    do: byte_size(content)

  defp previous_utf8_boundary(content, index) do
    if utf8_boundary?(content, index), do: index, else: previous_utf8_boundary(content, index - 1)
  end

  defp utf8_boundary?(content, index), do: String.valid?(binary_part(content, 0, index))

  defp matches?({:literal, regex}, text), do: Regex.match?(regex, text)
  defp matches?({:regex, regex}, text), do: Regex.match?(regex, text)

  defp matching_line_count(content, matcher) do
    content
    |> String.split("\n", trim: true)
    |> Enum.count(&matches?(matcher, &1))
  end

  defp max_results(tool, input) do
    value = Map.get(input, "max_results") || Map.get(input, :max_results) || tool.max_results

    if is_integer(value) and value > 0 do
      {:ok, value}
    else
      {:error, Error.new(:invalid_file_search_limit, "max_results must be a positive integer")}
    end
  end

  defp query_matcher(tool, input) do
    query = Map.get(input, "query") || Map.get(input, :query)
    mode = Map.get(input, "query_mode") || Map.get(input, :query_mode) || tool.query_mode

    case normalize_mode(mode, :query_mode, [:literal, :regex]) do
      {:ok, :literal} ->
        {:ok, {:literal, Regex.compile!(Regex.escape(query), "iu")}}

      {:ok, :regex} ->
        case Regex.compile(query) do
          {:ok, regex} ->
            {:ok, {:regex, regex}}

          {:error, reason} ->
            {:error,
             Error.new(:invalid_file_search_regex, "invalid file search regex", %{
               pattern: query,
               reason: inspect(reason)
             })}
        end

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp output_mode(tool, input) do
    mode = Map.get(input, "output_mode") || Map.get(input, :output_mode) || tool.output_mode
    normalize_mode(mode, :output_mode, [:content, :count])
  end

  defp normalize_mode(mode, field, modes) when is_atom(mode) do
    if mode in modes, do: {:ok, mode}, else: invalid_mode(field, mode, modes)
  end

  defp normalize_mode(mode, field, modes) when is_binary(mode) do
    normalized = Enum.find(modes, &(Atom.to_string(&1) == mode))

    if normalized do
      {:ok, normalized}
    else
      invalid_mode(field, mode, modes)
    end
  end

  defp normalize_mode(mode, field, modes), do: invalid_mode(field, mode, modes)

  defp invalid_mode(field, mode, modes) do
    {:error,
     Error.new(:invalid_file_search_option, "invalid file search #{field}", %{
       field: field,
       value: inspect(mode),
       expected: modes
     })}
  end

  defp compile_patterns(patterns) do
    patterns
    |> Enum.reduce_while({:ok, []}, fn pattern, {:ok, acc} ->
      with {:ok, expanded} <- expand_pattern(pattern),
           {:ok, regexes} <- compile_expanded_patterns(expanded) do
        {:cont, {:ok, acc ++ regexes}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, regexes} -> {:ok, Enum.reverse(regexes)}
      {:error, error} -> {:error, error}
    end
  end

  defp compile_expanded_patterns(patterns) do
    Enum.reduce_while(patterns, {:ok, []}, fn pattern, {:ok, acc} ->
      case compile_pattern(pattern) do
        {:ok, regex} -> {:cont, {:ok, [regex | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, regexes} -> {:ok, Enum.reverse(regexes)}
      {:error, error} -> {:error, error}
    end
  end

  defp expand_pattern(pattern) when is_binary(pattern) and pattern != "" do
    if String.contains?(pattern, <<0>>) or String.contains?(pattern, "\n") do
      invalid_pattern(pattern)
    else
      expand_braces(pattern)
    end
  end

  defp expand_pattern(pattern) do
    {:error,
     Error.new(:invalid_file_search_pattern, "file search pattern must be a non-empty string", %{
       pattern: inspect(pattern)
     })}
  end

  defp expand_braces(pattern) do
    case Regex.run(~r/\{([^{}]*)\}/, pattern, return: :index) do
      nil ->
        if String.contains?(pattern, ["{", "}"]) do
          invalid_pattern(pattern)
        else
          {:ok, [pattern]}
        end

      [{start, length}, {inner_start, inner_length}] ->
        inner = binary_part(pattern, inner_start, inner_length)
        options = String.split(inner, ",")

        if inner == "" or Enum.any?(options, &(&1 == "")) do
          invalid_pattern(pattern)
        else
          prefix = binary_part(pattern, 0, start)
          suffix_start = start + length
          suffix = binary_part(pattern, suffix_start, byte_size(pattern) - suffix_start)

          options
          |> Enum.reduce_while({:ok, []}, fn option, {:ok, acc} ->
            case expand_braces(prefix <> option <> suffix) do
              {:ok, expanded} -> {:cont, {:ok, acc ++ expanded}}
              {:error, error} -> {:halt, {:error, error}}
            end
          end)
        end
    end
  end

  defp compile_pattern(pattern) when is_binary(pattern) and pattern != "" do
    segments = Path.split(pattern)

    if Path.type(pattern) == :absolute or ".." in segments or
         Enum.any?(segments, &String.starts_with?(&1, "~")) do
      {:error,
       Error.new(:invalid_file_search_pattern, "file search patterns must stay within roots", %{
         pattern: pattern
       })}
    else
      {:ok, Regex.compile!("^" <> compile_segments(segments) <> "$")}
    end
  end

  defp compile_pattern(pattern), do: invalid_pattern(pattern)

  defp invalid_pattern(pattern) do
    {:error,
     Error.new(:invalid_file_search_pattern, "invalid file search include pattern", %{
       pattern: inspect(pattern)
     })}
  end

  defp compile_segments(["**"]), do: ".*"

  defp compile_segments(segments) do
    segments
    |> Enum.map_join("/", &compile_segment/1)
    |> String.replace("(?:[^/]+/)*/", "(?:[^/]+/)*")
  end

  defp compile_segment("**"), do: "(?:[^/]+/)*"

  defp compile_segment(segment) do
    segment
    |> String.graphemes()
    |> Enum.map_join(fn
      "*" -> "[^/]*"
      "?" -> "[^/]"
      char -> Regex.escape(char)
    end)
  end
end
