defmodule BeamWeaver.Filesystem.Utils do
  @moduledoc false

  alias BeamWeaver.Filesystem.FileDataUtils
  alias BeamWeaver.Filesystem.Format
  alias BeamWeaver.Filesystem.Path
  alias BeamWeaver.Filesystem.Search

  defdelegate binary_preview_bytes(), to: FileDataUtils
  defdelegate empty_content_warning(), to: FileDataUtils
  defdelegate max_line_length(), to: Format
  defdelegate line_number_width(), to: Format
  defdelegate tool_result_token_limit(), to: Format
  defdelegate truncation_guidance(), to: Format

  defdelegate sanitize_tool_call_id(tool_call_id), to: Path
  defdelegate to_posix_path(path), to: Path
  defdelegate validate_path(path, opts \\ []), to: Path
  defdelegate clean_path(path), to: Path
  defdelegate virtual_to_real(root, path), to: Path
  defdelegate under_path?(path, base), to: Path
  defdelegate relative(path, base), to: Path

  defdelegate file_data(content, opts \\ []), to: FileDataUtils
  defdelegate create_file_data(content, opts \\ []), to: FileDataUtils
  defdelegate update_file_data(data, content), to: FileDataUtils
  defdelegate file_data_to_string(content), to: FileDataUtils
  defdelegate check_empty_content(content), to: FileDataUtils
  defdelegate file_data_from_upload(content, opts \\ []), to: FileDataUtils
  defdelegate normalize_file_data(data), to: FileDataUtils
  defdelegate read_content(data, opts), to: FileDataUtils
  defdelegate encode_disk_file(path, virtual_path, opts \\ []), to: FileDataUtils
  defdelegate slice_lines(content, opts), to: FileDataUtils
  defdelegate maybe_slice_lines(content), to: FileDataUtils
  defdelegate slice_read_response(file_data, offset, limit), to: FileDataUtils
  defdelegate binary_content?(bytes), to: FileDataUtils
  defdelegate now(), to: FileDataUtils
  defdelegate error_string(reason), to: FileDataUtils

  defdelegate immediate_entries(files, path), to: Search
  defdelegate grep_files(files, pattern, opts \\ []), to: Search
  defdelegate grep_matches_from_files(files, pattern, opts \\ []), to: Search
  defdelegate glob_files(files, pattern, opts \\ []), to: Search
  defdelegate wildcard_match?(value, pattern), to: Search
  defdelegate build_grep_results_dict(matches), to: Search
  defdelegate format_grep_matches(matches, output_mode \\ :files_with_matches), to: Search
  defdelegate format_grep_results(results, output_mode \\ :files_with_matches), to: Search

  defdelegate count_occurrences(content, needle), to: Format
  defdelegate perform_string_replacement(content, old, new, opts \\ []), to: Format
  defdelegate format_content_with_line_numbers(content, opts \\ []), to: Format
  defdelegate truncate_if_too_long(result), to: Format
  defdelegate truncate_if_too_long(result, max_bytes), to: Format
  defdelegate truncate_if_too_long(content, max_bytes, guidance), to: Format
end
